-module(pobox_SUITE).
-include_lib("common_test/include/ct.hrl").
-compile(export_all).

all() -> [{group, queue}, {group, stack}, {group, keep_old}, {group, pobox_queue_buf}].
groups() ->
    %% Nested groups for eternal glory. We use one group to declare all the
    %% tests ('all' group), and then nest it in 'stack' and 'queue' groups,
    %% which all repeat the 'all' test but with a different implementation.
    [{queue, [], [{group, all}]},
     {stack, [], [{group, all}]},
     {keep_old, [], [{group, all}]},
     {pobox_queue_buf, [], [{group, all}]},
     {all, [], [notify_to_active, notify_to_overflow, no_api_post,
                filter_skip, filter_drop, active_to_notify,
                passive_to_notify, passive_to_active, resize,
                linked_owner, drop_count]}
    ].

%%%%%%%%%%%%%%
%%% MACROS %%%
%%%%%%%%%%%%%%
-define(wait_msg(PAT),
    (fun() ->
        receive
            PAT -> ok
        after 2000 ->
            error({wait_too_long})
        end
    end)()).

-define(wait_msg(PAT, RET),
    (fun() ->
        receive
            PAT -> RET
        after 2000 ->
            error({wait_too_long})
        end
    end)()).

%%%%%%%%%%%%%%%%%%%%%%%
%%% INIT & TEARDOWN %%%
%%%%%%%%%%%%%%%%%%%%%%%

init_per_suite(Config) -> Config.
end_per_suite(_Config) -> ok.

init_per_group(queue, Config) ->
    [{type, queue} | Config];
init_per_group(stack, Config) ->
    [{type, stack} | Config];
init_per_group(keep_old, Config) ->
    [{type, keep_old} | Config];
init_per_group(pobox_queue_buf, Config) ->
    [{type, {mod, pobox_queue_buf}} | Config];
init_per_group(_, Config) ->
    Config.

end_per_group(_, _Config) ->
    ok.

init_per_testcase(linked_owner, Config) ->
    [{size, 3} | Config];
init_per_testcase(_, Config) ->
    Type = ?config(type, Config),
    Size = 3,
    {ok, Pid} = pobox:start_link(self(), Size, Type),
    [{pobox, Pid}, {size, Size} | Config].

end_per_testcase(linked_owner, _Config) ->
    ok;
end_per_testcase(_, Config) ->
    Pid = ?config(pobox, Config),
    unlink(Pid),
    Ref = erlang:monitor(process, Pid),
    exit(Pid, shutdown),
    ?wait_msg({'DOWN', Ref, process, Pid, _}).

%%%%%%%%%%%%%
%%% TESTS %%%
%%%%%%%%%%%%%
notify_to_active(Config) ->
    %% Check that we can send messages to the POBox and it will notify us
    %% about it. We should then be able to set it to active and it should
    %% send us the messages back.
    Box = ?config(pobox, Config),
    Size = ?config(size, Config),
    Sent = lists:seq(1,Size),
    [pobox:post(Box, N) || N <- Sent],
    ?wait_msg({mail, Box, new_data}),
    pobox:active(Box, fun(X,State) -> {{ok,X}, State} end, no_state),
    Msgs = ?wait_msg({mail,Box,Msgs,Size,0}, Msgs),
    %% Based on the type, we have different guarantees
    case ?config(type, Config) of
        queue -> % queues are in order
            Sent = Msgs;
        {mod, pobox_queue_buf} -> % queues are in order
            Sent = Msgs;
        stack -> % We don't care for the order
            Sent = lists:sort(Msgs);
        keep_old -> % in order, no benefit for out-of-order
            Sent = Msgs
    end,
    %% messages are not repeated, and we get good state transitions
    Msg = Size+1,
    pobox:post(Box, Msg),
    pobox:active(Box, fun(X,State) -> {{ok,X}, State} end, no_state),
    ?wait_msg({mail,Box,[Msg],1,0}).

notify_to_overflow(Config) ->
    %% Check that we can send messages to the POBox and it will notify
    %% us about it, but also overflow and tell us about how many messages
    %% overflowed.
    Box = ?config(pobox, Config),
    Size = ?config(size, Config),
    [pobox:post(Box, N) || N <- lists:seq(1,Size*2)],
    ?wait_msg({mail, Box, new_data}),
    pobox:active(Box, fun(X,State) -> {{ok,X}, State} end, no_state),
    Msgs = ?wait_msg({mail,Box,Msgs,Size,Size}, Msgs),
    %% Based on the type, we have different guarantees
    case ?config(type, Config) of
        queue -> % queues are in order. We expect to have lost the 1st msgs
            Msgs = lists:seq(Size+1, Size*2); % we dropped 1..Size
        {mod, pobox_queue_buf} -> % queues are in order. We expect to have lost the 1st msgs
            Msgs = lists:seq(Size+1, Size*2); % we dropped 1..Size
        stack -> % We don't care for the order. We have all oldest + 1 newest
            Kept = lists:sort([Size*2 | lists:seq(1,Size-1)]),
            Kept = lists:sort(Msgs);
        keep_old -> % In order. We expect to have lost the last messages
            Msgs = lists:seq(1,Size)
    end.

no_api_post(Config) ->
    %% We want to support the ability to post directly without going through
    %% the API. This can be done by sending a message directly with the
    %% form {post, Msg}, for each message.
    Box = ?config(pobox, Config),
    Size = ?config(size, Config),
    Sent = lists:seq(1,Size),
    [Box ! {post,N} || N <- Sent],
    ?wait_msg({mail, Box, new_data}),
    pobox:active(Box, fun(X,State) -> {{ok,X}, State} end, no_state),
    Sent = lists:sort(?wait_msg({mail,Box,Msgs,Size,0}, Msgs)).

filter_skip(Config) ->
    %% The custom function to deal with the buffer can be used to
    %% skip entries. We skip after one entry to make a message-per-message
    %% fetch.
    Box = ?config(pobox, Config),
    Size = ?config(size, Config),
    true = Size >= 3, % The test will fail with less than 3 messages
    [pobox:post(Box, N) || N <- lists:seq(1,3)],
    ?wait_msg({mail, Box, new_data}),
    Filter = fun(X,0) -> {{ok,X}, 1};
                (_,_) -> skip
             end,
    pobox:active(Box, Filter, 0),
    [Msg1] = lists:sort(?wait_msg({mail,Box,Msgs,1,0}, Msgs)),
    pobox:active(Box, Filter, 0),
    [Msg2] = lists:sort(?wait_msg({mail,Box,Msgs,1,0}, Msgs)),
    pobox:active(Box, Filter, 0),
    [Msg3] = lists:sort(?wait_msg({mail,Box,Msgs,1,0}, Msgs)),
    case ?config(type, Config) of
        queue ->
            [1,2,3] = [Msg1, Msg2, Msg3];
        {mod, pobox_queue_buf} ->
            [1,2,3] = [Msg1, Msg2, Msg3];
        stack ->
            [3,2,1] = [Msg1, Msg2, Msg3];
        keep_old ->
            [1,2,3] = [Msg1, Msg2, Msg3]
    end.

filter_drop(Config) ->
    %% The custom function to deal with the buffer can be used to
    %% drop entries. We drop after one entry to make a message-per-message
    %% fetch that keeps no history.
    Box = ?config(pobox, Config),
    Size = ?config(size, Config),
    true = Size >= 3, % The test will fail with less than 3 messages
    [pobox:post(Box,N) || N <- lists:seq(1,3)],
    ?wait_msg({mail, Box, new_data}),
    Filter = fun(X,0) -> {{ok,X}, 1};
                (_,_) -> {drop, 1}
             end,
    pobox:active(Box, Filter, 0),
    MsgList = lists:sort(?wait_msg({mail,Box,Msgs,1,2}, Msgs)),
    pobox:post(Box, 4),
    pobox:active(Box, Filter, 0),
    [MsgExtra] = lists:sort(?wait_msg({mail,Box,Msgs,1,0}, Msgs)),
    case ?config(type, Config) of
        queue ->
            [1,4] = MsgList ++ [MsgExtra];
        {mod, pobox_queue_buf} ->
            [1,4] = MsgList ++ [MsgExtra];
        stack ->
            [3,4] = MsgList ++ [MsgExtra];
        keep_old ->
            [1,4] = MsgList ++ [MsgExtra]
    end.

active_to_notify(Config) ->
    %% It should be possible to take an active box, and make it go to notify
    %% to receive notifications instead of data
    Box = ?config(pobox, Config),
    pobox:active(Box, fun(X,State) -> {{ok,X}, State} end, no_state),
    pobox:post(Box, 1),
    ?wait_msg({mail,Box,[1],1,0}),
    {_, 0} = process_info(self(), message_queue_len), % no 'new_data'
    %% We should be in passive mode.
    passive = get_statename(Box),
    pobox:active(Box, fun(X,State) -> {{ok,X}, State} end, no_state),
    wait_until(fun() -> active_s =:= get_statename(Box) end, 100, 10),
    pobox:notify(Box),
    wait_until(fun() -> notify =:= get_statename(Box) end, 100, 10),
    pobox:post(Box, 2),
    ?wait_msg({mail, Box, new_data}),
    pobox:active(Box, fun(X,State) -> {{ok,X}, State} end, no_state),
    ?wait_msg({mail,Box,[2],1,0}).

passive_to_notify(Config) ->
    %% It should be possible to take a passive box, and make it 'notify'
    %% to receive notifications.
    Box = ?config(pobox, Config),
    pobox:active(Box, fun(X,State) -> {{ok,X}, State} end, no_state),
    pobox:post(Box, 1),
    ?wait_msg({mail,Box,[1],1,0}),
    {_, 0} = process_info(self(), message_queue_len), % no 'new_data'
    %% We should be in passive mode.
    passive = get_statename(Box),
    pobox:notify(Box),
    wait_until(fun() -> notify =:= get_statename(Box) end, 100, 10),
    %% Then we should be receiving notifications after a message
    pobox:post(Box, 2),
    ?wait_msg({mail, Box, new_data}),
    pobox:active(Box, fun(X,State) -> {{ok,X}, State} end, no_state),
    ?wait_msg({mail,Box,[2],1,0}),
    %% Back to passive. With a message in the mailbox, we should be able
    %% to notify then fall back to passive directly.
    passive = get_statename(Box),
    pobox:post(Box, 3),
    {_, 0} = process_info(self(), message_queue_len), % no 'new_data'
    pobox:notify(Box),
    ?wait_msg({mail, Box, new_data}),
    passive = get_statename(Box).

passive_to_active(Config) ->
    %% It should be possible to take a passive box, and make it active
    %% to receive messages without notifications.
    Box = ?config(pobox, Config),
    Filter = fun(X,State) -> {{ok,X},State} end,
    pobox:active(Box, fun(X,State) -> {{ok,X}, State} end, no_state),
    pobox:post(Box, 1),
    ?wait_msg({mail,Box,[1],1,0}),
    {_, 0} = process_info(self(), message_queue_len), % no 'new_data'
    %% We should be in passive mode.
    passive = get_statename(Box),
    pobox:active(Box, Filter, no_state),
    wait_until(fun() -> active_s =:= get_statename(Box) end, 100, 10),
    %% Then we should be receiving mail after a post
    pobox:post(Box, 2),
    ?wait_msg({mail,Box,[2],1,0}),
    {_, 0} = process_info(self(), message_queue_len), % no 'new_data'
    %% Back to passive. With a message in the mailbox, we should be able
    %% to activate then fall back to passive directly.
    passive = get_statename(Box),
    pobox:post(Box, 3),
    {_, 0} = process_info(self(), message_queue_len), % no 'new_data'
    pobox:active(Box, Filter, no_state),
    ?wait_msg({mail,Box,[3],1,0}),
    passive = get_statename(Box).

resize(Config) ->
    %% We should be able to resize the buffer up and down freely.
    Box = ?config(pobox, Config),
    Filter = fun(X,State) -> {{ok,X},State} end,
    pobox:resize(Box, 3),
    [pobox:post(Box, N) || N <- lists:seq(1,4)],
    ?wait_msg({mail, Box, new_data}), % POBox is full
    pobox:active(Box, Filter, no_state),
    ?wait_msg({mail,Box,_,3,1}), % then box is empty
    [pobox:post(Box, N) || N <- lists:seq(1,3)],
    pobox:resize(Box, 6),
    [pobox:post(Box, N) || N <- lists:seq(4,6)],
    pobox:active(Box, Filter, no_state),
    ?wait_msg({mail,Box,_,6,0}), % lost nothing
    [pobox:post(Box, N) || N <- lists:seq(1,6)],
    pobox:resize(Box, 3),
    pobox:active(Box, Filter, no_state),
    Kept = ?wait_msg({mail,Box,Msgs,3,3}, Msgs), % lost the surplus
    case ?config(type, Config) of
        queue ->
            Kept = [4,5,6];
        {mod, pobox_queue_buf} ->
            Kept = [4,5,6];
        stack ->
            Kept = [3,2,1];
        keep_old ->
            Kept = [1,2,3]
    end.

linked_owner(Config) ->
    Type = ?config(type, Config),
    Size = ?config(size, Config),
    Trap = process_flag(trap_exit, true),
    %% Can link to a regular process and catch the failure
    Owner0 = spawn_link(fun() -> timer:sleep(infinity) end),
    {ok,Box0} = pobox:start_link(Owner0, Size, Type),
    wait_until(fun() -> 2 =:= length(element(2, process_info(Box0, links))) end, 100, 10),
    wait_until(fun() -> 2 =:= length(element(2, process_info(Owner0, links))) end, 100, 10),
    exit(Owner0, shutdown),
    ?wait_msg({'EXIT', Owner0, _}),
    ?wait_msg({'EXIT', Box0, _}),
    %% Same thing works with named processes
    Owner1 = spawn_link(fun() -> timer:sleep(infinity) end),
    erlang:register(pobox_owner, Owner1),
    {ok,Box1} = pobox:start_link(pobox_owner, Size, Type),
    wait_until(fun() -> 2 =:= length(element(2, process_info(Box1, links))) end, 100, 10),
    wait_until(fun() -> 2 =:= length(element(2, process_info(Owner1, links))) end, 100, 10),
    exit(Owner1, shutdown),
    ?wait_msg({'EXIT', Owner1, _}),
    ?wait_msg({'EXIT', Box1, _}),
    %% Unlinking totally makes things work with multiple procs though
    Owner2 = spawn_link(fun() ->
       receive {From, pobox, Pid} ->
            unlink(Pid),
            From ! ok,
            timer:sleep(infinity)
       end
     end),
    erlang:register(pobox_owner, Owner2),
    {ok,Box2} = pobox:start_link(pobox_owner, Size, Type),
    wait_until(fun() -> 2 =:= length(element(2, process_info(Box2, links))) end, 100, 10),
    wait_until(fun() -> 2 =:= length(element(2, process_info(Owner2, links))) end, 100, 10),
    Owner2 ! {self(), pobox, Box2},
    ?wait_msg(ok),
    exit(Owner2, shutdown),
    ?wait_msg({'EXIT', Owner2, _}),
    true = is_process_alive(Box2),
    exit(Box2, different_reason),
    ?wait_msg({'EXIT', Box2, different_reason}),
    process_flag(trap_exit, Trap).

drop_count(Config) ->
    Type = ?config(type, Config),
    Size = ?config(size, Config),
    {ok, Box} = pobox:start_link(self(), Size, Type),
    %% post and manually drop 3 messages, should be able to do it again
    %% many times without a problem
    [pobox:post(Box, N) || N <- lists:seq(1,Size)],
    pobox:active(Box, fun(_, S) -> {drop, S} end, nostate),
    ?wait_msg({mail, Box, [], 0, Size}),
    [pobox:post(Box, N) || N <- lists:seq(1,Size)],
    pobox:active(Box, fun(_, S) -> {drop, S} end, nostate),
    ?wait_msg({mail, Box, [], 0, Size}),
    [pobox:post(Box, N) || N <- lists:seq(1,Size)],
    pobox:active(Box, fun(_, S) -> {drop, S} end, nostate),
    ?wait_msg({mail, Box, [], 0, Size}),
    [pobox:post(Box, N) || N <- lists:seq(1,Size)],
    pobox:active(Box, fun(_, S) -> {drop, S} end, nostate),
    ?wait_msg({mail, Box, [], 0, Size}),
    [pobox:post(Box, N) || N <- lists:seq(1,Size)],
    pobox:active(Box, fun(_, S) -> {drop, S} end, nostate),
    ?wait_msg({mail, Box, [], 0, Size}),
    true = is_process_alive(Box),
    unlink(Box),
    exit(Box, shutdown).


%%%%%%%%%%%%%%%
%%% HELPERS %%%
%%%%%%%%%%%%%%%
get_statename(Pid) ->
    {State, _} = sys:get_state(Pid),
    State.

wait_until(Fun, _, 0) -> error({timeout, Fun});
wait_until(Fun, Interval, Tries) ->
    case Fun() of
        true -> ok;
        false ->
            timer:sleep(Interval),
            wait_until(Fun, Interval, Tries-1)
    end.

