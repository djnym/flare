-module(flare_topic_buffer).
-include("flare_internal.hrl").
-include_lib("shackle/include/shackle.hrl").

-compile(inline).
-compile({inline_size, 512}).

-export([
    init/5,
    produce/4,
    start_link/4
]).

%% sys behavior
-export([
    system_code_change/4,
    system_continue/3,
    system_get_state/1,
    system_terminate/4
]).

-define(SAMPLE_RATE_ERROR, 0.1).
-define(SAMPLE_RATE_OK, 0.005).

-record(state, {
    acks             :: 1..65535,
    buffer = []      :: list(),
    buffer_count = 0 :: non_neg_integer(),
    buffer_delay_max :: pos_integer(),
    buffer_size = 0  :: non_neg_integer(),
    buffer_size_max  :: undefined | pos_integer(),
    compression      :: compression(),
    partitions       :: undefined | list(),
    name             :: atom(),
    parent           :: pid(),
    requests = []    :: requests(),
    timer_ref        :: undefined | reference(),
    topic            :: topic_name(),
    topic_key        :: binary()
}).

-type state() :: #state {}.

%% public
-spec init(pid(), buffer_name(), topic_name(), topic_opts(),
        partition_tuples()) -> no_return().

init(Parent, Name, Topic, Opts, Partitions) ->
    process_flag(trap_exit, true),
    register(Name, self()),
    proc_lib:init_ack(Parent, {ok, self()}),

    Acks = ?LOOKUP(acks, Opts, ?DEFAULT_TOPIC_ACKS),
    BufferDelayMax = ?LOOKUP(buffer_delay, Opts,
        ?DEFAULT_TOPIC_BUFFER_DELAY),
    BufferSizeMax = ?LOOKUP(buffer_size, Opts,
        ?DEFAULT_TOPIC_BUFFER_SIZE),
    Compression = flare_utils:compression(?LOOKUP(compression, Opts,
        ?DEFAULT_TOPIC_COMPRESSION)),

    loop(#state {
        acks = Acks,
        buffer_delay_max = BufferDelayMax,
        buffer_size_max = BufferSizeMax,
        compression = Compression,
        name = Name,
        parent = Parent,
        partitions = Partitions,
        timer_ref = timer(BufferDelayMax),
        topic = Topic,
        topic_key = topic_key(Topic)
    }).

-spec produce([msg()], requests(), pid(), state()) ->
    ok.

produce(Messages, Requests, Pid, #state {
        acks = Acks,
        buffer_count = BufferCount,
        compression = Compression,
        partitions = Partitions,
        topic = Topic,
        topic_key = TopicKey
    }) ->

    statsderl:increment([<<"flare.produce.">>, TopicKey,
        <<".batch.call">>], 1, ?SAMPLE_RATE_OK),
    statsderl:increment([<<"flare.produce.">>, TopicKey,
        <<".message.call">>], BufferCount + 1, ?SAMPLE_RATE_OK),
    Timestamp = os:timestamp(),

    Messages2 = flare_protocol:encode_message_set(lists:reverse(Messages)),
    Messages3 = flare_utils:compress(Compression, Messages2),
    {Partition, PoolName, _} = shackle_utils:random_element(Partitions),
    Request = flare_protocol:encode_produce(Topic, Partition, Messages3,
        Acks, Compression),
    Cast = {produce, Request, BufferCount},
    {ok, ReqId} = shackle:cast(PoolName, Cast, Pid),
    flare_queue:add(ReqId, PoolName, Requests),

    Diff = timer:now_diff(os:timestamp(), Timestamp),
    statsderl:timing([<<"flare.produce.">>, TopicKey,
        <<".call">>], Diff, ?SAMPLE_RATE_OK).

-spec start_link(buffer_name(), topic_name(), topic_opts(),
        partition_tuples()) -> {ok, pid()}.

start_link(Name, Topic, Opts, Partitions) ->
    InitOpts = [self(), Name, Topic, Opts, Partitions],
    proc_lib:start_link(?MODULE, init, InitOpts).

%% sys callbacks
-spec system_code_change(state(), module(), undefined | term(), term()) ->
    {ok, state()}.

system_code_change(State, _Module, _OldVsn, _Extra) ->
    {ok, State}.

-spec system_continue(pid(), [], state()) ->
    ok.

system_continue(_Parent, _Debug, State) ->
    loop(State).

-spec system_get_state(state()) ->
    {ok, state()}.

system_get_state(State) ->
    {ok, State}.

-spec system_terminate(term(), pid(), [], state()) ->
    none().

system_terminate(Reason, _Parent, _Debug, _State) ->
    exit(Reason).

%% private
async_produce(Buffer, Requests, State) ->
    spawn(?MODULE, produce, [Buffer, Requests, self(), State]).

handle_msg(?MSG_TIMEOUT, #state {
        buffer = [],
        buffer_delay_max = BufferDelayMax
    } = State) ->

    {ok, State#state {
        timer_ref = timer(BufferDelayMax)
    }};
handle_msg(?MSG_TIMEOUT, #state {
        buffer = Buffer,
        buffer_delay_max = BufferDelayMax,
        requests = Requests
    } = State) ->

    async_produce(Buffer, Requests, State),

    {ok, State#state {
        buffer = [],
        buffer_count = 0,
        buffer_size = 0,
        requests = [],
        timer_ref = timer(BufferDelayMax)
    }};
handle_msg(?MSG_RELOAD_METADATA, #state {topic = Topic} = State) ->
    case flare_metadata:partitions(Topic) of
        {ok, Partitions} ->
            flare_broker_pool:start(Partitions),

            {ok, State#state {
                partitions = Partitions
            }};
        {error, Reason} ->
            shackle_utils:warning_msg(?CLIENT,
                "metadata reload failed: ~p~n", [Reason]),
            {ok, State}
    end;
handle_msg({produce, ReqId, Message, Pid}, #state {
        buffer = Buffer,
        buffer_count = BufferCount,
        buffer_size = BufferSize,
        buffer_size_max = SizeMax,
        requests = Requests
    } = State) ->

    Buffer2 = [Message | Buffer],
    Requests2 = [{ReqId, Pid} | Requests],

    case BufferSize + iolist_size(Message) of
        Size when Size > SizeMax ->
            async_produce(Buffer2, Requests2, State),

            {ok, State#state {
                buffer = [],
                buffer_count = 0,
                buffer_size = 0,
                requests = []
            }};
        Size ->
            {ok, State#state {
                buffer = Buffer2,
                buffer_count = BufferCount + 1,
                buffer_size = Size,
                requests = Requests2
            }}
    end;
handle_msg(#cast {
        client = ?CLIENT,
        reply = {ok, {_, _, ErrorCode, _}},
        request = {_, _, Count},
        request_id = ReqId
    }, #state {
        topic_key = TopicKey
    } = State) ->

    Response = flare_response:error_code(ErrorCode),
    reply(ReqId, Response, TopicKey, Count),
    {ok, State};
handle_msg(#cast {
        client = ?CLIENT,
        reply = {error, _Reason} = Error,
        request = {_, _, Count},
        request_id = ReqId
    }, #state {
        topic_key = TopicKey
    } = State) ->

    reply(ReqId, Error, TopicKey, Count),
    {ok, State}.

loop(#state {parent = Parent} = State) ->
    receive
        {'EXIT', _Pid, shutdown} ->
            terminate(State);
        {system, From, Request} ->
            sys:handle_system_msg(Request, From, Parent, ?MODULE, [], State);
        Message ->
            {ok, State2} = handle_msg(Message, State),
            loop(State2)
    end.

reply(ReqId, ok, TopicKey, Count) ->
    statsderl_produce_ok(TopicKey, Count),
    reply_all(ReqId, ok);
reply(ReqId, {error, not_leader_for_partition} = Error, TopicKey, Count) ->
    self() ! ?MSG_RELOAD_METADATA,
    statsderl_produce_error(TopicKey, Count, not_leader_for_partition),
    reply_all(ReqId, Error);
reply(ReqId, {error, unknown_topic_or_partition} = Error, TopicKey, Count) ->
    self() ! ?MSG_RELOAD_METADATA,
    statsderl_produce_error(TopicKey, Count, unknown_topic_or_partition),
    reply_all(ReqId, Error);
reply(ReqId, {error, Reason} = Error, TopicKey, Count) ->
    statsderl_produce_error(TopicKey, Count, Reason),
    reply_all(ReqId, Error).

reply_all([], _Response) ->
    ok;
reply_all([{_, undefined} | T], Response) ->
    reply_all(T, Response);
reply_all([{ReqId, Pid} | T], Response) ->
    Pid ! {ReqId, Response},
    reply_all(T, Response);
reply_all(ReqId, Response) ->
    case flare_queue:remove(ReqId) of
        {ok, {_PoolName, Requests}} ->
            reply_all(Requests, Response);
        {error, not_found} ->
            shackle_utils:warning_msg(?CLIENT,
                "reply error: ~p~n", [not_found]),
            ok
    end.

statsderl_produce_ok(TopicKey, Count) ->
    statsderl:increment([<<"flare.produce.">>, TopicKey,
        <<".batch.ok">>], 1, 0.01),
    statsderl:increment([<<"flare.produce.">>, TopicKey,
        <<".message.ok">>], Count, 0.01).

statsderl_produce_error(TopicKey, Count, Reason) ->
    statsderl:increment([<<"flare.produce.">>, TopicKey,
        <<".batch.error">>], 1, ?SAMPLE_RATE_ERROR),
    statsderl:increment([<<"flare.produce.">>, TopicKey,
        <<".message.error">>], Count, ?SAMPLE_RATE_ERROR),
    ReasonBin = atom_to_binary(Reason, latin1),
    statsderl:increment([<<"flare.produce.">>, TopicKey,
        <<".error.">>, ReasonBin], 1, ?SAMPLE_RATE_ERROR).

terminate(#state {
        requests = Requests,
        timer_ref = TimerRef
    }) ->

    reply_all(Requests, {error, shutdown}),
    erlang:cancel_timer(TimerRef),
    exit(shutdown).

timer(Time) ->
    erlang:send_after(Time, self(), ?MSG_TIMEOUT).

topic_key(Topic) ->
    binary:replace(Topic, <<".">>, <<"_">>, [global]).
