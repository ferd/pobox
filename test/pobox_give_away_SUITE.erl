-module(pobox_give_away_SUITE).
-include_lib("common_test/include/ct.hrl").
-include_lib("stdlib/include/assert.hrl").
-include_lib("eunit/include/eunit.hrl").
-compile(export_all).

all() -> [
  owner_gives_away_ownership,
  owner_gives_away_ownership_with_data,
  owner_gives_away_ownership_to_dead_process,
  foreign_process_tries_to_gives_away_ownership,
  give_away_does_not_change_heir,
  owner_gives_away_ownership_when_in_notify,
  owner_gives_away_ownership_when_in_active
].

owner_gives_away_ownership(_Config) ->
    {ok, Box} = pobox:start_link(#{size => 10}),
    Self = self(),
    H = erlang:spawn_link(fun F () -> receive X -> Self ! X end, F() end),
    ?assert(pobox:give_away(Box, H, 5000)),
    ?assertMatch(
        {pobox_transfer, Box, Self, undefined, give_away},
        receive
            Res -> Res
        after
            5000 -> timeout
        end
    ).

owner_gives_away_ownership_with_data(_Config) ->
    {ok, Box} = pobox:start_link([{size, 10}]),
    Self = self(),
    H = erlang:spawn_link(fun F () -> receive X -> Self ! X end, F() end),
    Ref = make_ref(),
    ?assert(pobox:give_away(Box, H, Ref, 5000)),
    ?assertMatch(
      {pobox_transfer, Box, Self, Ref, give_away},
      receive
          Res -> Res
      after
          5000 -> timeout
      end
    ).

owner_gives_away_ownership_to_dead_process(_Config) ->
    {ok, Box} = pobox:start_link([{size, 10}]),
    Self = self(),
    H = erlang:spawn(fun F () -> receive X -> Self ! X end, F() end),
    erlang:exit(H, kill),
    timer:sleep(100),
    ?assertNot(pobox:give_away(Box, H, 5000)),
    ?assert(receive
         _ -> false
    after
        100 -> true
    end).


foreign_process_tries_to_gives_away_ownership(_Config) ->
    {ok, Box} = pobox:start_link([{size, 10}]),
    Self = self(),
    erlang:spawn_link(fun() -> Self ! pobox:give_away(Box, self(), 5000) end),
    ?assertNot(receive Res -> Res end).

give_away_does_not_change_heir(_Config) ->
    Self = self(),
    {ok, Box} = pobox:start_link([{heir, Self}, {heir_data, first}, {size, 10}]),
    H = erlang:spawn(fun() -> receive X -> Self ! X end, throw("crash") end),
    ?assert(pobox:give_away(Box, H, second, 5000)),
    ?assertMatch(
      {pobox_transfer, Box, Self, second, give_away},
      receive
          Res -> Res
      after
          5000 -> timeout
      end
    ),
    ?assertMatch(
        {pobox_transfer, Box, H, first, Reason} when Reason =/= give_away,
        receive
            Res -> Res
        after
            5000 -> timeout
        end
    ).

owner_gives_away_ownership_when_in_notify(_Config) ->
    {ok, Box} = pobox:start_link([{size, 10}]),
    ok = pobox:notify(Box),
    Self = self(),
    H = erlang:spawn_link(fun F () -> receive X -> Self ! X end, F() end),
    ?assertMatch(notify, element(1, sys:get_state(Box))),
    ?assert(pobox:give_away(Box, H, 5000)),
    ?assertMatch(
        {pobox_transfer, Box, Self, undefined, give_away},
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

owner_gives_away_ownership_when_in_active(_Config) ->
    {ok, Box} = pobox:start_link([{size, 10}]),
    ok = pobox:active(Box, fun(_Msg, _) -> skip end, nostate),
    Self = self(),
    H = erlang:spawn_link(fun F () -> receive X -> Self ! X end, F() end),
    ?assertMatch(active_s, element(1, sys:get_state(Box))),
    ?assert(pobox:give_away(Box, H, 5000)),
    ?assertMatch(
        {pobox_transfer, Box, Self, undefined, give_away},
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