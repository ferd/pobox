-module(pobox_state_changer).

-behaviour(gen_server).

%% API
-export([start_link/4, get_pobox/1, stop/1]).

%% gen_server callbacks
-export([init/1,
    handle_call/3,
    handle_cast/2,
    handle_info/2,
    terminate/2,
    code_change/3]).

-define(SERVER, ?MODULE).

-record(state, {pobox, behaviours, crash_vector, vector}).

start_link(Heir, Behaviours, CrashVector, BufType) ->
    gen_server:start_link(?MODULE, [Heir, Behaviours, CrashVector, BufType], []).

get_pobox(Pid) ->
    gen_server:call(Pid, get_pobox).

stop(Pid) ->
    gen_server:call(Pid, stop).

init([Heir, Behaviours, CrashVector, BufType]) ->
    %erlang:process_flag(error_handler, undefined),
    {ok, Box} = pobox:start_link(#{max => 10, heir=>Heir, type => BufType}),
    {ok, #state{pobox=Box, behaviours=Behaviours, crash_vector=CrashVector, vector=0}}.

handle_call(stop, From, State) ->
    gen_server:reply(From, ok),
    {stop, normal, State};
handle_call(get_pobox, _From, State = #state{pobox=Box}) ->
    {reply, Box, State};
handle_call(_Request, _From, State) ->
    {reply, ok, State}.


handle_cast(_Request, State) ->
    {noreply, State}.

handle_info(_, State = #state{crash_vector=Vector, vector=Vector}) ->
    {stop, fake_crash, State};
handle_info(_, State = #state{behaviours=[]}) ->
    {stop, normal, State};
handle_info(_, State = #state{vector=Vector, behaviours = [Behaviour | Behaviours]}) ->
    do_behaviour(Behaviour, State),
    {noreply, State#state{vector=Vector + 1, behaviours = Behaviours}};
handle_info(_Info, State) ->
    {noreply, State}.

terminate(_Reason, _State) ->
    ok.

code_change(_OldVsn, State, _Extra) ->
    {ok, State}.

do_behaviour({wait, Time}, State) ->
    timer:sleep(Time),
    State;
do_behaviour(notify, State = #state{pobox=Box}) ->
    pobox:notify(Box),
    State;
do_behaviour({active, all}, State = #state{pobox=Box}) ->
    pobox:active(Box, fun(Msg, nostate) -> {{ok, Msg}, nostate} end, nostate),
    State;
do_behaviour({active, Batch}, State = #state{pobox=Box}) ->
    pobox:active(
        Box,
        fun
            (_Msg, Count) when Count =:= Batch ->
                skip;
            (Msg, Count) ->
                {{ok, Msg}, Count + 1}
        end,
        0
    ),
    State.
