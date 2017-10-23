%%%-------------------------------------------------------------------
%% @copyright Fred Hebert, Geoff Cant
%% @author Fred Hebert <mononcqc@ferd.ca>
%% @author Geoff Cant <nem@erlang.geek.nz>
%% @doc Generic process that acts as an external mailbox and a
%% message buffer that will drop requests as required. For more
%% information, see README.txt
%% @end
%%%-------------------------------------------------------------------
-module(pobox).
-behaviour(gen_statem).
-compile({no_auto_import,[size/1]}).

-ifdef(namespaced_types).
-record(buf, {type = undefined :: undefined | 'stack' | 'queue' | 'keep_old',
              max = undefined :: undefined | max(),
              size = 0 :: non_neg_integer(),
              drop = 0 :: drop(),
              data = undefined :: undefined | queue:queue() | list()}).
-else.
-record(buf, {type = undefined :: undefined | 'stack' | 'queue' | 'keep_old',
              max = undefined :: undefined | max(),
              size = 0 :: non_neg_integer(),
              drop = 0 :: drop(),
              data = undefined :: undefined | queue() | list()}).
-endif.

-type max() :: pos_integer().
-type drop() :: non_neg_integer().
-type buffer() :: #buf{}.
-type filter() :: fun( (Msg::term(), State::term()) ->
                        {{ok,NewMsg::term()} | drop , State::term()} | skip).

-type in() :: {'post', Msg::term()}.
-type note() :: {'mail', Self::pid(), new_data}.
-type mail() :: {'mail', Self::pid(), Msgs::list(),
                         Count::non_neg_integer(), Lost::drop()}.
-type name() :: {local, atom()} | {global, term()} | atom() | pid() | {via, module(), term()}.

-export_type([max/0, filter/0, in/0, mail/0, note/0]).

-record(state, {buf :: buffer(),
                owner :: pid(),
                filter :: undefined | filter(),
                filter_state :: undefined | term()}).

-export([start_link/3, start_link/4, start_link/5, 
        resize/2, active/3, notify/1, post/2]).
-export([init/1,
         active_s/3, passive/3, notify/3,
         callback_mode/0, terminate/3, code_change/4]).

%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%
%%% API Function Definitions %%%
%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%

%% @doc Starts a new buffer process. The implementation can either
%% be a stack or a queue, depending on which messages will be dropped
%% (older ones or newer ones). Note that stack buffers do not guarantee
%% message ordering.
%% The initial state can be either passive or notify, depending on whether
%% the user wants to get notifications of new messages as soon as possible.
-spec start_link(name(), max(), 'stack' | 'queue') -> {ok, pid()}.
start_link(Owner, Size, Type) ->
    start_link(Owner, Size, Type, notify).

%% This one is messy because we have two clauses with 4 values, so we look them
%% up based on guards.
-spec start_link(name(), max(), 'stack' | 'queue', 'notify'|'passive') -> {ok, pid()}
        ;       (term(), pid(), max(), stack | queue) -> {ok, pid()}.
start_link(Owner, Size, Type, StateName) when is_pid(Owner);
                                              is_atom(Owner),
                                              is_integer(Size), Size > 0 ->
    gen_statem:start_link(?MODULE, {Owner, Size, Type, StateName}, []);
start_link(Name, Owner, Size, Type) ->
    start_link(Name, Owner, Size, Type, notify).

-spec start_link(name(), pid(), max(), stack | queue,
                 'notify'|'passive') -> {ok, pid()}.
start_link(Name, Owner, Size, Type, StateName) when Size > 0,
                                                    Type =:= queue orelse
                                                    Type =:= stack orelse
                                                    Type =:= keep_old,
                                                    StateName =:= notify orelse
                                                    StateName =:= passive ->
    gen_statem:start_link(Name, ?MODULE, {Owner, Size, Type, StateName}, []).

%% @doc Allows to take a given buffer, and make it larger or smaller.
%% A buffer can be made larger without overhead, but it may take
%% more work to make it smaller given there could be a
%% need to drop messages that would now be considered overflow.
-spec resize(name(), max()) -> ok.
resize(Box, NewSize) when NewSize > 0 ->
    gen_statem:call(Box, {resize, NewSize}).

%% @doc Forces the buffer into an active state where it will
%% send the data it has accumulated. The fun passed needs to have
%% two arguments: A message, and a term for state. The function can return,
%% for each element, a tuple of the form {Res, NewState}, where `Res' can be:
%% - `{ok, Msg}' to receive the message in the block that gets shipped
%% - `drop' to ignore the message
%% - `skip' to stop removing elements from the stack, and keep them for later.
-spec active(name(), filter(), State::term()) -> ok.
active(Box, Fun, FunState) when is_function(Fun,2) ->
    gen_statem:cast(Box, {active_s, Fun, FunState}).

%% @doc Forces the buffer into its notify state, where it will send a single
%% message alerting the Owner of new messages before going back to the passive
%% state.
-spec notify(name()) -> ok.
notify(Box) ->
    gen_statem:cast(Box, notify).

%% @doc Sends a message to the PO Box, to be buffered.
-spec post(name(), term()) -> ok.
post(Box, Msg) ->
    gen_statem:cast(Box, {post, Msg}).

%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%
%%% gen_statem Function Definitions %%%
%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%

callback_mode() ->
    state_functions.

%% @private
init({Owner, Size, Type, StateName}) ->
    if is_pid(Owner)  -> link(Owner);
       is_atom(Owner) -> link(whereis(Owner))
    end,
    {ok, StateName, #state{buf = buf_new(Type, Size), owner=Owner}}.

%% @private
active_s(cast, {active_s, Fun, FunState}, S = #state{}) ->
    {next_state, active_s, S#state{filter=Fun, filter_state=FunState}};
active_s(cast, notify, S = #state{}) ->
    {next_state, notify, S#state{filter=undefined, filter_state=undefined}};
active_s(cast, {post, Msg}, S = #state{buf=Buf}) ->
    NewBuf = insert(Msg, Buf),
    send(S#state{buf=NewBuf});
active_s(cast, _Msg, _State) ->
    %% unexpected
    keep_state_and_data;
active_s({call, From}, Msg, Data) ->    
    handle_call(From, Msg, Data);
active_s(info, Msg, Data) ->    
    handle_info(Msg, active_s, Data).

%% @private
passive(cast, notify, State = #state{buf=Buf}) ->
    case size(Buf) of
        0 -> {next_state, notify, State};
        N when N > 0 -> send_notification(State)
    end;
passive(cast, {active_s, Fun, FunState}, S = #state{buf=Buf}) ->
    NewState = S#state{filter=Fun, filter_state=FunState},
    case size(Buf) of
        0 -> {next_state, active_s, NewState};
        N when N > 0 -> send(NewState)
    end;
passive(cast, {post, Msg}, S = #state{buf=Buf}) ->
    {next_state, passive, S#state{buf=insert(Msg, Buf)}};
passive(cast, _Msg, _State) ->
    %% unexpected
    keep_state_and_data;
passive({call, From}, Msg, Data) ->    
    handle_call(From, Msg, Data);
passive(info, Msg, Data) ->    
    handle_info(Msg, passive, Data).

%% @private
notify(cast, {active_s, Fun, FunState}, S = #state{buf=Buf}) ->
    NewState = S#state{filter=Fun, filter_state=FunState},
    case size(Buf) of
        0 -> {next_state, active_s, NewState};
        N when N > 0 -> send(NewState)
    end;
notify(cast, notify, S = #state{}) ->
    {next_state, notify, S};
notify(cast, {post, Msg}, S = #state{buf=Buf}) ->
    send_notification(S#state{buf=insert(Msg, Buf)});
notify(cast, _Msg, _State) ->
    %% unexpected
    keep_state_and_data;
notify({call, From}, Msg, Data) ->    
    handle_call(From, Msg, Data);
notify(info, Msg, Data) ->    
    handle_info(Msg, notify, Data).
        

%% @private
handle_call(From, {resize, NewSize}, S=#state{buf=Buf}) ->
    {keep_state, S#state{buf=resize_buf(NewSize,Buf)}, 
        [{reply, From, ok}]};

handle_call(_From, _Msg, _Data) ->
    %% die of starvation, caller!
    keep_state_and_data.

%% @private
handle_info({post, Msg}, StateName, State) ->
    %% We allow anonymous posting and redirect it to the internal form.
    ?MODULE:StateName(cast, {post, Msg}, State);

handle_info(_Info, _StateName, _State) ->
    keep_state_and_data.

%% @private
terminate(_Reason, _StateName, _State) ->
    ok.

%% @private
code_change(_OldVsn, StateName, State, _Extra) ->
    {ok, StateName, State}.

%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%
%%% Private Function Definitions %%%
%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%

send(S=#state{buf = Buf, owner=Pid, filter=Fun, filter_state=FilterState}) ->
    {Msgs, Count, Dropped, NewBuf} = buf_filter(Buf, Fun, FilterState),
    Pid ! {mail, self(), Msgs, Count, Dropped},
    NewState = S#state{buf=NewBuf, filter=undefined, filter_state=undefined},
    {next_state, passive, NewState}.

send_notification(S = #state{owner=Owner}) ->
    Owner ! {mail, self(), new_data},
    {next_state, passive, S}.

%%% Generic buffer ops
-spec buf_new('queue' | 'stack' | 'keep_old', max()) -> buffer().
buf_new(queue, Size) -> #buf{type=queue, max=Size, data=queue:new()};
buf_new(stack, Size) -> #buf{type=stack, max=Size, data=[]};
buf_new(keep_old, Size) -> #buf{type=keep_old, max=Size, data=queue:new()}.

insert(Msg, B=#buf{type=T, max=Size, size=Size, drop=Drop, data=Data}) ->
    B#buf{drop=Drop+1, data=push_drop(T, Msg, Size, Data)};
insert(Msg, B=#buf{type=T, size=Size, data=Data}) ->
    B#buf{size=Size+1, data=push(T, Msg, Data)}.

size(#buf{size=Size}) -> Size.

resize_buf(NewMax, B=#buf{max=Max}) when Max =< NewMax ->
    B#buf{max=NewMax};
resize_buf(NewMax, B=#buf{type=T, size=Size, drop=Drop, data=Data}) ->
    if Size > NewMax ->
        ToDrop = Size - NewMax,
        B#buf{size=NewMax, max=NewMax, drop=Drop+ToDrop,
              data=drop(T, ToDrop, Size, Data)};
       Size =< NewMax ->
        B#buf{max=NewMax}
    end.

buf_filter(Buf=#buf{type=T, drop=D, data=Data, size=C}, Fun, State) ->
    {Msgs, Count, Dropped, NewData} = filter(T, Data, Fun, State),
    {Msgs, Count, Dropped+D, Buf#buf{drop=0, size=C-(Count+Dropped), data=NewData}}.

filter(T, Data, Fun, State) ->
    filter(T, Data, Fun, State, [], 0, 0).

filter(T, Data, Fun, State, Msgs, Count, Drop) ->
    case pop(T, Data) of
        {empty, NewData} ->
            {lists:reverse(Msgs), Count, Drop, NewData};
        {{value,Msg}, NewData} ->
            case Fun(Msg, State) of
                {{ok, Term}, NewState} ->
                    filter(T, NewData, Fun, NewState, [Term|Msgs], Count+1, Drop);
                {drop, NewState} ->
                    filter(T, NewData, Fun, NewState, Msgs, Count, Drop+1);
                skip ->
                    {lists:reverse(Msgs), Count, Drop, Data}
            end
    end.

%% Specific buffer ops
push_drop(keep_old, _Msg, _Size, Data) -> Data;
push_drop(T, Msg, Size, Data) -> push(T, Msg, drop(T, Size, Data)).

drop(T, Size, Data) -> drop(T, 1, Size, Data).

drop(_, 0, _Size, Data) -> Data;
drop(queue, 1, _Size, Queue) -> queue:drop(Queue);
drop(stack, 1, _Size, [_|T]) -> T;
drop(keep_old, 1, _Size, Queue) -> queue:drop_r(Queue);
drop(queue, N, Size, Queue) ->
    if Size > N  -> element(2, queue:split(N, Queue));
       Size =< N -> queue:new()
    end;
drop(stack, N, Size, L) ->
    if Size > N  -> lists:nthtail(N, L);
       Size =< N -> []
    end;
drop(keep_old, N, Size, Queue) ->
    if Size > N  -> element(1, queue:split(N, Queue));
       Size =< N -> queue:new()
    end.

push(queue, Msg, Q) -> queue:in(Msg, Q);
push(stack, Msg, L) -> [Msg|L];
push(keep_old, Msg, Q) -> queue:in(Msg, Q).

pop(queue, Q) -> queue:out(Q);
pop(stack, []) -> {empty, []};
pop(stack, [H|T]) -> {{value,H}, T};
pop(keep_old, Q) -> queue:out(Q).
