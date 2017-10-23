# PO Box

High throughput Erlang applications often get bitten by the fact that
Erlang mailboxes are unbounded and will keep accepting messages until the
node runs out of memory.

In most cases, this problem can be solved by imposing a rate limit on
the producers, and it is recommended to explore this idea before looking
at this library.

When it is impossible to rate-limit the messages coming to a process and
that your optimization efforts remain fruitless, you need to start
shedding load by dropping messages.

PO Box can help by shedding the load for you, and making sure you won't
run out of memory.

## The Principles

PO Box is a library that implements a buffer process.  Erlang processes
will receive their messages locally (at home), and may become overloaded
because they have to both deal with their mailbox and day-to-day tasks:

             messages
                |
                V
    +-----[Pid or Name]-----+
    |      |         |      |
    |      | mailbox |      |
    |      +---------+      |
    |       |               |
    |    receive            |
    +-----------------------+

A PO Box process will be where you will ask for your messages to go
through. The PO Box process will implement a buffer (see *Types of
Buffer* for details) that will do nothing but churn through messages and
drop them when the buffer is full for you.

Depending on how you use the API, the PO Box can tell you it received new data,
so you can then ask for the data, or you can tell it to  send the data to you
directly, without notification:

                                                      messages
                                                         |
                                                         V
    +---------[Pid]---------+                +--------[POBox]--------+
    |                       |<-- got mail ---|      |         |      |
    |                       |                |      | mailbox |      |
    |   <important stuff>   |--- send it! -->|      +---------+      |
    |                       |                |       |               |
    |                       |<---<messages>--|<---buffer             |
    +-----------------------+                +-----------------------+

To be more detailed, a PO Box is a state machine with an owner process
(which it receives messages for), and it has 3 states:

- Active
- Notify
- Passive

The passive state basically does nothing but accumulate messages in the
buffer and drop them when necessary.

The notify state is enabled by the user by calling the PO Box. Its sole
task is to verify if there is any message in the buffer. If there is, it
will respond to the PO Box's owner with a `{mail, new_data}` message
sent directly to the pid. If there is no message in the buffer, the
process will wait in the notify state until it gets one. As soon as the
notification is sent, it reverts back to the passive state.

The active state is the only one that can send actual messages to the
owner process. The user can call the PO Box to set it active, and if
there are any messages in the buffer, all the messages it contains get
sent as a list to the owner. If there are no messages, the PO Box waits
until there is one to send it. After forwarding the messages, the PO Box
reverts to the passive state.

The FSM can be illustrated as crappy ASCII as:

             ,---->[passive]------(user makes active)----->[active]
             |         | ^                                  |  ^  |
             |         | '---(sends message to user)--<-----'  |  |
             |  (user makes notify)                            |  |
             |         |                                       |  |
    (user is notified) |                                       |  |
             |         V                                       |  |
             '-----[notify]---------(user makes active)--------'  |
                         ^----------(user makes notify)<----------'

## Types of buffer

Currently, there are three types of buffers supported: queues and stacks,
and `keep_old` queues.

Queues will keep messages in order, and drop oldest messages to make
place for new ones. If you have a buffer of size 3 and receive messages
a, b, c, d, e in that order, the buffer will contain messages `[c,d,e]`.

`keep_old` queues will keep messages in order, but block newer messages
from entering, favoring keeping old messages instead. If you have a
buffer of size 3 and receive messages a, b, c, d, e in that order, the
buffer will contain messages `[a,b,c]`.

Stacks will not guarantee any message ordering, and will drop the top of
the stack to make place for the new messages first. for the same
messages, the stack buffer should contain the messages `[e,b,a]`.

To choose between a queue and a stack buffer, you should consider the
following criterias:

- Do you need messages in order? Choose one of the queues.
- Do you need the latest messages coming in to be kept, or the oldest
  ones? If so, pick `queue` and `keep_old`, respectively.
- Do you need low latency? Then choose a stack. Stacks will give you
  many messages with low latency with a few with high latency. Queues
  will give you a higher overall latency, but less variance over time.

More buffer types could be supported in the future, if people require
them.

## How to build it

    ./rebar compile

## How to run tests

    ./rebar compile ct

## How to use it

Start a buffer with any of the following:

    start_link(OwnerPid, MaxSize, BufferType)
    start_link(OwnerPid, MaxSize, BufferType, InitialState)
    start_link(Name, OwnerPid, MaxSize, BufferType)
    start_link(Name, OwnerPid, MaxSize, BufferType, InitialState)

Where:

- `Name` is any name a regular `gen_fsm` process can accept (including
  `{via,...}` tuples)
- `OwnerPid` is the pid of the PO Box owner. It's the only one that can
  communicate with it in terms of setting state and reading messages.
  The `OwnerPid` can be either a pid or an atom. The PO Box will set up
  a link directly between itself and `OwnerPid`, and won't trap exits.
  If you're using named processes (atoms) and want to have the PO Box
  survive them individually, you should unlink the processes manually.
  This also means that processes that terminate normally won't kill the
  POBox.
- `MaxSize` is the maximum number of messages in a buffer.
- `BufferType` can be either `queue` or `stack` and specifies which type
  is going to be used.
- `InitialState` can be either `passive` or `notify`. The default value
  is set to `notify`. Having the buffer passive is desirable when you
  start it during an asynchronous `init` and do not want to receive
  notifications right away.

The buffer can be made active by calling:

    pobox:active(BoxPid, FilterFun, FilterState)

The `FilterFun` is a function that will take messages one by one along
with custom state and can return:

- `{{ok, Message}, NewState}`: the message will be sent.
- `{drop, NewState}`: the message will be dropped.
- `skip`: the message is left in the buffer and whatever was filtered so
  far gets sent.

A function that would blindly forward all messages could be written as:

    fun(Msg, _) -> {{ok,Msg},nostate} end

A function that would limit binary messages by size could be written as:

    fun(Msg, Allowed) ->
        case Allowed - byte_size(Msg) of
            N when N < 0 -> skip;
            N -> {{ok, Msg}, N}
        end
    end

Or you could drop messages that are empty binaries by doing:

    fun(<<>>, State) -> {drop, State};
       (Msg, State) -> {{ok,Msg}, State}
    end.

The resulting message sent will be:

    {mail, BoxPid, Messages, MessageCount, MessageDropCount}

Finally, the PO Box can be forced to notify by calling:

    pobox:notify(BoxPid)

Which is objectively much simpler.

Messages can be sent to a PO Box by calling `pobox:post(BoxPid, Msg)` or
sending a message directly to the process as `BoxPid ! {post, Msg}`.

## Example Session

First start a PO Box for the current process:

    1> {ok, Box} = pobox:start_link(self(), 10, queue).
    {ok,<0.39.0>}

We'll also define a spammer function that will just keep mailing a bunch
of messages:

    2> Spam = fun(F,N) -> pobox:post(Box,N), F(F,N+1) end.
    #Fun<erl_eval.12.17052888>

Because we're in the shell, the function takes itself as an argument so
it can both remain anonymous and loop. Each message is an increasing
integer.

I can start the process and wait for a while:

    3> Spammer = spawn(fun() -> Spam(Spam,0) end).
    <0.42.0>

Let's see if we have anything in our PO box:

    4> flush().
    Shell got {mail,new_data}
    ok

Yes! Let's get that content:

    5> pobox:active(Box, fun(X,ok) -> {{ok,X},ok} end, ok).
    ok
    6> flush().
    Shell got {mail,<0.39.0>,
                    [778918,778919,778920,778921,778922,778923,778924,778925,
                     778926,778927],
                    10,778918}
    ok

So we have 10 messages with seqential IDs (we used a queue buffer), and
the process kindly dropped over 700,000 messages for us, keeping our
node's memory safe.

The spammer is still going and our PO Box is in passive mode. Let's cut
to the chase and go directly to the active state:

    7> pobox:active(Box, fun(X,ok) -> {{ok,X},ok} end, ok).
    ok
    8> flush().
    Shell got {mail,<0.39.0>,
                    [1026883,1026884,1026885,1026886,1026887,1026888,1026889,
                     1026890,1026891,1026892],
                    10,247955}
    ok

Nice. We can go back to notification mode too:

    9> pobox:notify(Box).
    ok
    10> flush().
    Shell got {mail,new_data}
    ok

And keep going on and on and on.

## Notes

- Be careful to have a lightweight filter function if you expect constant
  overload from messages that keep coming very very fast. While the
  buffer filters out whatever messages you have, the new ones keep
  accumulating in the PO Box's own mailbox!
- It is possible for a process to have multiple PO Boxes, although
  coordinating the multiple state machines together may get tricky.
- The library is a generalization of ideas designed and implemented in
  logplex by Geoff Cant's (@archaelus). Props to him.
- Using a `keep_old` buffer with a filter function that selects one message
  at a time would be equivalent to a naive bounded mailbox similar to what
  plenty of users asked for before. Tricking the filter function to
  forward the message (`self() ! Msg`) while dropping it will allow
  to do selective receives on bounded mailboxes.

## Contributing

Accepted contributions need to be non-aesthetic, and provide some new
functionality, fix abstractions, improve performance or semantics, and
so on.

All changes received must be tested and not break existing tests.

Changes to currently untested functionality should ideally first provide
a separate commit that shows the current behaviour working with the new
tests (or some of the new tests, if you expand on the functionality),
and then your own feature (and additional tests if required) in its own
commit so we can verify nothing breaks in unpredictable ways.

Tests are written using Common Test. PropEr tests will be accepted,
because they objectively rule. Ideally, you will wrap your PropEr tests
in a Common Test suite so we can run everything with one command.

If you need help, feel free to ask for it in issues or pull requests.
These rules are strict, but we're nice people!

## Roadmap

This is more a wishlist than a roadmap, in no particular order:

- Implement `give_away` and/or `heir` functionality to PO Boxes to make them
  behave like ETS tables, or possibly just implementing `controlling_process`
  to make them behave more like ports. Right now the semantics are those of
  a mailbox, provided nobody unlinks the POBox from its owner process.
- Provide default filter functions in a new module

## Changelog

- 1.0.4: move to gen\_statem implementation to avoid OTP 21 compile errors and OTP 20 warnings
- 1.0.3: fix typespecs to generate fewer errors
- 1.0.2: explicitly specify `registered` to be `[]` for
         relx compatibility, switch to rebar3
- 1.0.1: fixing bug where manually dropped messages (with the active filter)
         would result in wrong size values and crashes for queues.
- 1.0.0: A PO Box links itself to the process that it receives data for.
- 0.2.0: Added PO Box's pid in the `newdata` message so a process can own more
         than a PO Box. Changed internal queue and stack size monitoring to be
         O(1) in all cases.
- 0.1.1: adding `keep_old` queue, which blocks new messages from entering
         a filled queue.
- 0.1.0: initial commit

## Authors / Thanks

- Fred Hebert / @ferd: library generalization and current implementation
- Geoff Cant / @archaelus: design, original implementation
