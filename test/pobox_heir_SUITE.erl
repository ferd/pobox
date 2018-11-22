-module(pobox_heir_SUITE).
-include_lib("common_test/include/ct.hrl").
-include_lib("stdlib/include/assert.hrl").
-include_lib("eunit/include/eunit.hrl").
-compile(export_all).

all() -> [
    with_local_registered_name_owner,
    with_global_registered_name_owner,
    with_global_registered_name_heir,
    with_via_registered_name_owner,
    owner_crashes_heir_takes_over,
    heir_dies_then_owner_dies,
    goes_to_passive_mode_when_in_notify,
    goes_to_passive_mode_when_in_active
].


with_local_registered_name_owner(_Config) ->
    Self = self(),
    Ref = make_ref(),
    PreviousOwnerPid = erlang:spawn(fun() ->
        {ok, Box} = pobox:start_link({local, ?MODULE}, #{heir => Self, heir_data => Ref, size => 10}),
        Self ! Box,
        throw("crash")
    end),
    Box = receive
        BoxPid when is_pid(BoxPid) -> BoxPid
    after
        100 -> false
    end,
    ?assertMatch(
        {pobox_transfer, Box, PreviousOwnerPid, Ref, _},
        receive
            Res -> Res
        after
            5000 -> timeout
        end
    ).


with_global_registered_name_owner(_Config) ->
    Self = self(),
    Ref = make_ref(),
    PreviousOwnerPid = erlang:spawn(fun() ->
        {ok, Box} = pobox:start_link({global, ?MODULE}, [{heir, Self}, {heir_data, Ref}, {size, 10}]),
        Self ! Box,
        throw("crash")
    end),
    Box = receive
        BoxPid when is_pid(BoxPid) -> BoxPid
    after
        100 -> false
    end,
    ?assertMatch(
        {pobox_transfer, Box, PreviousOwnerPid, Ref, _},
        receive
            Res -> Res
        after
            5000 -> timeout
        end
    ).


with_global_registered_name_heir(_Config) ->
    Self = self(),
    Ref = make_ref(),
    yes = global:register_name(my_global_name, self()),
    PreviousOwnerPid = erlang:spawn(fun() ->
        {ok, Box} = pobox:start_link([{heir, {global, my_global_name}}, {heir_data, Ref}, {size, 10}]),
        Self ! Box,
        throw("crash")
    end),
    Box = receive
        BoxPid when is_pid(BoxPid) -> BoxPid
    after
        100 -> false
    end,
    ?assertMatch(
        {pobox_transfer, Box, PreviousOwnerPid, Ref, _},
        receive
            Res -> Res
        after
            5000 -> timeout
        end
    ).

with_via_registered_name_owner(_Config) ->
    Self = self(),
    Ref = make_ref(),
    PreviousOwnerPid = erlang:spawn(fun() ->
        {ok, Box} = pobox:start_link({via, global, fake_name}, [{heir, Self}, {heir_data, Ref}, {size, 10}]),
        Self ! Box,
        throw("crash")
    end),
    Box = receive
        BoxPid when is_pid(BoxPid) -> BoxPid
    after
        100 -> false
    end,
    ?assertMatch(
        {pobox_transfer, Box, PreviousOwnerPid, Ref, _},
        receive
            Res -> Res
        after
            5000 -> timeout
        end
    ).


owner_crashes_heir_takes_over(_Config) ->
    Self = self(),
    Ref = make_ref(),
    PreviousOwnerPid = erlang:spawn(fun() ->
        {ok, Box} = pobox:start_link([{heir, Self}, {heir_data, Ref}, {size, 10}]),
        Self ! Box,
        throw("crash")
    end),
    Box = receive
        BoxPid when is_pid(BoxPid) -> BoxPid
    after
        100 -> false
    end,
    ?assertMatch(
        {pobox_transfer, Box, PreviousOwnerPid, Ref, _},
        receive
            Res -> Res
        after
            5000 -> timeout
        end
    ).

heir_dies_then_owner_dies(_Config) ->
    Self = self(),
    Dest = erlang:spawn_link(fun() -> receive _ -> Self ! continue end end),
    {ok, Box} = pobox:start_link([{heir, Self}, {heir_data, heir_data}, {size, 10}]),
    ?assert(pobox:give_away(Box, Dest, dest_data, 500)),
    ?assertMatch(continue, receive
      Res -> Res
    after
        5000 -> timeout
    end),
    ?assertMatch(
      {pobox_transfer, Box, Dest, heir_data, Reason} when Reason =/= give_away,
      receive
          Res -> Res
      after
          5000 -> timeout
      end
    ).

goes_to_passive_mode_when_in_notify(_Config) ->
    Self = self(),
    Ref = make_ref(),
    PreviousOwnerPid = erlang:spawn(fun() ->
        {ok, Box} = pobox:start_link(#{heir => Self, heir_data => Ref, size => 10}),
        ok = pobox:notify(Box),
        Self ! Box,
        throw("crash")
    end),
    Box = receive
        BoxPid when is_pid(BoxPid) -> BoxPid
    after
        100 -> false
    end,
    ?assertMatch(
        {pobox_transfer, Box, PreviousOwnerPid, Ref, _},
        receive
            Res -> Res
        after
            5000 -> timeout
        end
    ),
    ?assert(
        receive
            _ -> false
        after
            100 -> true
        end
    ),
    ?assertMatch(passive, element(1, sys:get_state(Box))).

goes_to_passive_mode_when_in_active(_Config) ->
    Self = self(),
    Ref = make_ref(),
    PreviousOwnerPid = erlang:spawn(fun() ->
        {ok, Box} = pobox:start_link([{heir, Self}, {heir_data, Ref}, {size, 10}]),
        ok = pobox:active(Box, fun(_Msg, _) -> skip end, nostate),
        Self ! Box,
        timer:sleep(100),
        throw("crash")
    end),
    Box = receive
        BoxPid when is_pid(BoxPid) -> BoxPid
    after
        100 -> false
    end,
    ?assertMatch(active_s, element(1, sys:get_state(Box))),
    ?assertMatch(
        {pobox_transfer, Box, PreviousOwnerPid, Ref, _},
        receive
            Res -> Res
        after
            5000 -> timeout
        end
    ),
    ?assert(
        receive
            _ -> false
        after
            100 -> true
        end
    ),
    ?assertMatch(passive, element(1, sys:get_state(Box))).



