-module(flare_client).
-include("flare_internal.hrl").

-compile(inline).
-compile({inline_size, 512}).

-behavior(shackle_client).
-export([
    init/0,
    setup/2,
    handle_request/2,
    handle_data/2,
    terminate/1
]).

-record(state, {
    request_counter = 0 :: non_neg_integer()
}).

-type state() :: #state {}.

%% shackle_server callbacks
-spec init() ->
    {ok, state()}.

init() ->
    {ok, #state {}}.

-spec setup(inet:socket(), state()) ->
    {ok, state()}.

setup(_Socket, State) ->
    {ok, State}.

-spec handle_request(term(), state()) ->
    {ok, non_neg_integer(), iolist(), state()}.

handle_request({produce, Topic, Partition, Msgs, Acks, Compression}, #state {
        request_counter = RequestCounter
    } = State) ->

    RequestId = request_id(RequestCounter),
    % TODO: split encoding in two phase (MessageSet outside of client)
    Data = flare_protocol:encode_produce(RequestId, ?CLIENT_ID, Topic,
        Partition, Msgs, Acks, Compression),

    {ok, RequestId, Data, State#state {
        request_counter = RequestCounter + 1
    }}.

-spec handle_data(binary(), state()) ->
    {ok, [{pos_integer(), term()}], state()}.

handle_data(Data, State) ->
    {CorrelationId, [{topic, Topic, [
            {partition, Partition, ErrorCode, Offset}
        ]}]} = flare_protocol:decode_produce(Data),
    Response = {ok, {Topic, Partition, ErrorCode, Offset}},
    {ok, [{CorrelationId, Response}], State}.

-spec terminate(state()) -> ok.

terminate(_State) ->
    ok.

%% private
request_id(RequestCounter) ->
    RequestCounter rem ?MAX_REQUEST_ID.