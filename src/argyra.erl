%%%
%%% Copyright (c) 2017 The Talla Authors. All rights reserved.
%%% Use of this source code is governed by a BSD-style
%%% license that can be found in the LICENSE file.
%%%
%%%-------------------------------------------------------------------
%%% @author Lasse Grinderslev Andersen <lasse@etableret.dk>
%%% @doc Tor node controller library via Tor Control protocol.
%%% @end
%%%-------------------------------------------------------------------
-module(argyra).

-behaviour(gen_statem).

%% API
-export([start_link/2,
        set_events/1,
        getinfo/1,
        close_circuit/1,
        setconf/1,
        create_circuit/1,
        add_expected_event/1
        ]).

%% States
-export([idle/3,
         receiving_answer/3,
         receiving_getinfo_answer/3,
         receiving_create_circuit_answer/3
        ]).


%% gen_statem callbacks
-export([init/1,
         terminate/3,
         callback_mode/0,
         code_change/4]).

-define(FROM_TOR(Msg), {tcp, _Socket, Msg}).

-record(state, {address, port, socket, from, continuation=none, expected_events}).

-type state() :: #state {}.

%%%===================================================================
%%% API
%%%===================================================================

%%--------------------------------------------------------------------
%% @doc
%% Starts the server
%%
%% @spec start_link() -> {ok, Pid} | ignore | {error, Error}
%% @end
%%--------------------------------------------------------------------
start_link(Address, Port) ->
    gen_statem:start_link({local, ?MODULE}, ?MODULE, [Address, Port], []).

set_events(Events) ->
    gen_statem:call(?MODULE, {set_events, Events}).

getinfo(KeyWord) ->
    Response = gen_statem:call(?MODULE, {getinfo, KeyWord}),
    ParsedResponse = parse_getinfo_response(KeyWord, Response, []),
    {ok, ParsedResponse}.

setconf(Option) ->
    gen_statem:call(?MODULE, {setconf, Option}).

close_circuit(CiruitId) ->
    gen_statem:call(?MODULE, {close_circuit, CiruitId}).

create_circuit(OnionRouters) ->
    gen_statem:call(?MODULE, {create_circuit, OnionRouters}).

add_expected_event(Event) ->
    gen_statem:call(?MODULE, {add_expected_event, Event}).

%%%===================================================================
%%% gen_statem callbacks
%%%===================================================================

%%--------------------------------------------------------------------
%% @private
%% @doc
%% Initializes the server
%%
%% @spec init(Args) -> {ok, State} |
%%                     {ok, State, Timeout} |
%%                     ignore |
%%                     {stop, Reason}
%% @end
%%--------------------------------------------------------------------
init([Address, Port]) ->
    {ok, Socket} = gen_tcp:connect(Address, Port, [binary, {packet, line}, {active, true}]),
    StateData = #state {
                   address         = Address,
                   port            = Port,
                   socket          = Socket,
                   expected_events = #{}
                  },
    send("authenticate \"\"", StateData),
    receive
        {tcp, _Socket, <<"250 OK\r\n">>} ->
            {ok, idle, StateData}
    after
        20000 ->
            {stop, normal, StateData}
    end.


idle({call, {Caller, _} = From}, {add_expected_event, Event},
        #state { expected_events = ExpectedEvents } = State) ->
    NewState = State#state {
                 expected_events = ExpectedEvents#{ Event => Caller }
                },
    {next_state, idle, NewState, {reply, From, ok}};

idle({call, From}, {getinfo, KeyWord}, State) ->
    send("getinfo " ++ KeyWord, State),
    {next_state, receiving_getinfo_answer, State#state { from = From }};

idle({call, From}, {close_circuit, CiruitId}, State) ->
    send("closecircuit " ++ CiruitId, State),
    {next_state, receiving_answer, State#state { from = From }};

idle({call, From}, {setconf, Option}, State) ->
    send("setconf " ++ Option, State),
    {next_state, receiving_answer, State#state { from = From }};

idle({call, From}, {set_events, Events}, State) ->
    send("setevents " ++ Events, State),
    {next_state, receiving_answer, State#state { from = From }};

idle({call, From}, {create_circuit, OnionRouters}, State) ->
    OnionRoutersBin = [ binary_to_list(ORouter) || ORouter <- OnionRouters ],
    send("extendcircuit 0 $" ++ string:join(OnionRoutersBin, ",$"), State),
    {next_state, receiving_create_circuit_answer, State#state { from = From }};

idle(info, {tcp, _Socket, Event}, State) ->
    log_msg(Event),
    NewState = handle_event(Event, State),
    {next_state, idle, NewState}.



receiving_getinfo_answer(info, ?FROM_TOR(<<"650 ", _/binary>> = Event), State) ->
    log_msg(Event),
    NewState = handle_event(Event, State),
    {next_state, receiving_getinfo_answer, NewState};

receiving_getinfo_answer(info, ?FROM_TOR(<<"250-", Response/binary>>), #state { from = From } = State) ->
    % The response is containted in this msg
    gen_statem:reply(From, [Response]),
    {next_state, idle, State#state { from = none }};

receiving_getinfo_answer(info, ?FROM_TOR(<<"250+", _Rest/binary>>), State) ->
    % This msg only says that more data is coming, updating state accordingly
    {next_state, receiving_getinfo_answer, State#state { continuation = [] }};

receiving_getinfo_answer(info, ?FROM_TOR(<<".\r\n">>), State) ->
    {next_state, receiving_getinfo_answer, State};

receiving_getinfo_answer(info, ?FROM_TOR(<<"250 OK\r\n">>), #state { from = From, continuation = Continuation } = State) ->
    gen_statem:reply(From, Continuation),
    {next_state, idle, State#state { continuation = none, from = none }};

receiving_getinfo_answer(info, ?FROM_TOR(Response), #state { continuation = Continuation } = State) ->
    {next_state, receiving_getinfo_answer, State#state { continuation = [ Response | Continuation ] }}.


receiving_create_circuit_answer(info, ?FROM_TOR(<<"250 EXTENDED ", CircuitId/binary>>), #state { from = From } = State) ->
    gen_statem:reply(From, CircuitId),
    {next_state, idle, State#state { from = none } };

receiving_create_circuit_answer(info, ?FROM_TOR(<<"650 ", Event/binary>>), State) ->
    log_msg(<<"650", Event/binary>>),
    NewState = handle_event(Event, State),
    {next_state, receiving_create_circuit_answer, NewState};

receiving_create_circuit_answer(info, ?FROM_TOR(Msg), State) ->
    % FIXME this part is not finished since we have never actually created a succesful circuit yet
    log_msg(Msg),
    {next_state, receiving_create_circuit_answer, State}.


receiving_answer(info, ?FROM_TOR(<<"250 OK\r\n">>),
         #state { from = From } = State) ->
    gen_statem:reply(From, ok),
    {next_state, idle, State#state { from = none } };

receiving_answer(info, ?FROM_TOR(<<"650 ", Event/binary>>), State) ->
    log_msg(<<"650", Event/binary>>),
    NewState = handle_event(Event, State),
    {next_state, receiving_answer, NewState};

receiving_answer(info, ?FROM_TOR(AnswerChunk),
         #state { continuation = Continuation } = State) ->
    case Continuation of
        none ->
            {next_state, receiving_answer, State#state { continuation = [ AnswerChunk ] } };
        _ ->
            {next_state, receiving_answer, State#state { continuation = [ AnswerChunk | Continuation ] } }
    end.

handle_event(<<"650 ORCONN $", IdentityKeyDigest:40/binary, _Rest/binary>>, State) ->
    Event = {or_connection_established, IdentityKeyDigest},
    notify_on_expected_event(Event, State);

handle_event(<<"650 NEWDESC $", IdentityKeyDigest:40/binary, _Rest/binary>>, State) ->
    Event = {dir_announcement, IdentityKeyDigest},
    notify_on_expected_event(Event, State);

handle_event(_Event, State) ->
    State.


-spec callback_mode() -> gen_statem:callback_mode().
callback_mode() ->
    state_functions.

-spec terminate(Reason, StateName, StateData) -> ok
    when
        Reason    :: term(),
        StateName :: atom(),
        StateData :: state().
terminate(Reason, StateName, #state { socket = Socket }) ->
    log_msg(io_lib:format("Shutting down Argyra: ~p (~s)", [Reason, StateName])),
    gen_tcp:close(Socket),
    ok.

-spec code_change(Version, StateName, StateData, Extra) -> {ok, NewStateName, NewStateData}
    when
        Version         :: {down, term()} | term(),
        StateName       :: atom(),
        StateData       :: state(),
        Extra           :: term(),
        NewStateName    :: StateName,
        NewStateData    :: StateData.
code_change(_Version, StateName, StateData, _Extra) ->
    {ok, StateName, StateData}.

%%%===================================================================
%%% Internal functions
%%%===================================================================
send(Msg, #state { socket = Socket }) ->
    BMsg = list_to_binary(Msg),
    lager:notice("TorControl: Sending '~s'", [BMsg]),
    ok = gen_tcp:send(Socket, <<BMsg/binary, "\n">>).


notify_on_expected_event(Event, #state { expected_events = ExpectedEvents } = State) ->
    case maps:find(Event, ExpectedEvents) of
        {ok, Caller} ->
            Caller ! {event_occured, Event},
            State#state { expected_events=maps:remove(Event, ExpectedEvents) };
        error ->
            State
    end.


parse_getinfo_response(_KeyWord, [], ParsedResponse) ->
    ParsedResponse;

parse_getinfo_response("circuit-status", [ <<"circuit-status=\r\n">> ], []) ->
    [];

parse_getinfo_response("circuit-status", [ Circuit | Rest ], ParsedCiruits) ->
    [CircuitId | CircuitInfo] = binary:split(Circuit, <<" BUILT ">>),
    parse_getinfo_response("circuit-status", Rest, [{binary:bin_to_list(CircuitId), CircuitInfo} | ParsedCiruits]);

parse_getinfo_response(ResponseType, Response, _ParsedResponse) ->
    log_msg(io_lib:format("Unkown response type ~p", [ResponseType])),
    Response.

log_msg(Event) ->
    lager:notice("TorControl: '~s'", [Event]).
