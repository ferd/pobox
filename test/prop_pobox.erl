-module(prop_pobox).
-include_lib("proper/include/proper.hrl").
-export([
    prop_we_always_go_to_passive_mode_after_an_automatic_transfer/0,
    prop_we_always_go_to_passive_mode_after_a_give_away_transfer/0,
    prop_will_discard_after_max/0
]).

-type pobox_max() :: pos_integer().
-type pobox_initial_state() :: passive | notify.
-type crash_vector() :: pos_integer().
-type give_away_vector() :: pos_integer().
-type message() :: {msg, binary()} | {resize, pos_integer()} | usage.
-type messaging_strategy() :: async | sync | info.
-type messaging_behaviour() :: {non_neg_integer(), messaging_strategy(), message()}.
-type automatic_behaviour() :: {wait, non_neg_integer()} | notify | {active, non_neg_integer() | all}.
-type give_away_behaviour() :: {wait, non_neg_integer()} | notify | {active, non_neg_integer() | all}.
-type buffer_type() :: queue | keep_old | stack | {mod, pobox_queue_buf}.
-type automatic_scenario() :: {crash_vector(), list(automatic_behaviour()), list(messaging_behaviour()), buffer_type()}.
-type give_away_scenario() :: {give_away_vector(), list(give_away_behaviour()), list(messaging_behaviour()), buffer_type()}.
-type max_scenario() :: {pobox_max(), buffer_type(), pobox_initial_state()}.

prop_we_always_go_to_passive_mode_after_an_automatic_transfer() ->
    %% Random message sequence
    %% Random behaviour sequence
    %% Crash at random time vector
    %% pobox should be in passive mode
    erlang:process_flag(trap_exit, true),
    ?FORALL(_Scenario = {CrashVector, Behaviours, MessagingBehaviours, BufType}, automatic_scenario(), begin
        {ok, SCPid} = pobox_state_changer:start_link(self(), Behaviours, CrashVector, BufType),
        Box = pobox_state_changer:get_pobox(SCPid),
        %io:format("~p~n", [Scenario]),
        Procs = [erlang:spawn_opt(node(), fun() -> do_messaging_behaviour(Box, MessagingBehaviour) end, [monitor])
            || MessagingBehaviour <- MessagingBehaviours
        ],
        lists:map(
            fun({Pid, Ref}) ->
                receive
                    {'DOWN', Ref, _Type, Pid, _Info} -> ok
                after
                    20000 -> ok
                end
            end,
            Procs
        ),
        case is_process_alive(SCPid) of
            true -> catch pobox_state_changer:stop(SCPid);
            false -> ok
        end,
        receive
            {pobox_transfer, Box, SCPid, undefined, _Reason} ->
                element(1, sys:get_state(Box)) =:= passive
        after
            20000 -> false
        end

    end).


prop_we_always_go_to_passive_mode_after_a_give_away_transfer() ->
    ?FORALL(_Scenario = {GiveAwayVector, Behaviours, MessagingBehaviours, BufType}, give_away_scenario(), begin
        {ok, GAPid} = pobox_give_away:start_link(self(), Behaviours, GiveAwayVector, BufType),
        Box = pobox_give_away:get_pobox(GAPid),
        Procs = [erlang:spawn_opt(node(), fun() -> catch do_messaging_behaviour(Box, MessagingBehaviour) end, [monitor])
            || MessagingBehaviour <- MessagingBehaviours
        ],
        lists:map(
            fun({Pid, Ref}) ->
                receive
                    {'DOWN', Ref, _Type, Pid, _Info} -> ok
                after
                    20000 -> ok
                end
            end,
            Procs
        ),
        pobox_give_away:give_away(GAPid),
        receive
            {pobox_transfer, Box, _, undefined, _} ->
                element(1, sys:get_state(Box)) =:= passive
        after
            20000 -> false
        end
    end).


prop_will_discard_after_max() ->
    ?FORALL({MaxSize, BufType, InitialState}, max_scenario(), begin
        {ok, Box} = pobox:start_link(#{max => MaxSize, type => BufType, initial_state => InitialState}),
        length(lists:filter(
            fun(full) -> true; (ok) -> false end,
            [pobox:post_sync(Box, N, 5000) || N <- lists:seq(1, MaxSize * 2)]
        )) =:= MaxSize
    end).

do_messaging_behaviour(Box, {Time, _, {resize, MaxSize}}) ->
    timer:sleep(Time),
    pobox:resize(Box, MaxSize);
do_messaging_behaviour(Box, {Time, _, usage}) ->
    timer:sleep(Time),
    pobox:usage(Box);
do_messaging_behaviour(Box, {Time, async, Msg={msg, _}}) ->
    timer:sleep(Time),
    pobox:post(Box, Msg);
do_messaging_behaviour(Box, {Time, sync, Msg={msg, _}}) ->
    timer:sleep(Time),
    pobox:post_sync(Box, Msg);
do_messaging_behaviour(Box, {Time, info, Msg={msg, _}}) ->
    timer:sleep(Time),
    Box ! {post, Msg}.

