-module(pobox_queue_buf).

-behaviour(pobox_buf).
%% API
-export([new/0, push/2, pop/1, drop/2, push_drop/2]).

new() ->
  queue:new().

push(Msg, Q) ->
  queue:in(Msg, Q).

pop(Q) ->
  queue:out(Q).

drop(N, Q) ->
  element(2, queue:split(N, Q)).

push_drop(Msg, Q) ->
  push(Msg, drop(1, Q)).
