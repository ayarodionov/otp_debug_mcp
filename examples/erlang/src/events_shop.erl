%% A node that runs out of memory. events_source sends 50,000 events a
%% second to events_writer, which stores one a millisecond at best: the
%% writer's mailbox grows by about 10 MB a second, until the node, which
%% run.sh lets use only 300 MB, can't allocate more and dies, writing a
%% crash dump.
-module(events_shop).
-export([start/0]).

start() ->
    Writer = spawn(fun() -> writer(0) end),
    register(events_writer, Writer),
    register(events_source, spawn(fun() -> source(Writer, 0) end)),
    ok.

writer(Stored) ->
    receive
        {event, _Source, _Seq, _Data} = Event ->
            store(Event),
            writer(Stored + 1)
    end.

%% Storage takes a millisecond an event.
store(_Event) ->
    timer:sleep(1).

%% 500 events every 10 ms.
source(Writer, Seq) ->
    Now = erlang:system_time(millisecond),
    [Writer ! {event, clicks, Seq + I, #{page => <<"/products">>, user => (Seq + I) rem 977, at => Now}}
     || I <- lists:seq(1, 500)],
    timer:sleep(10),
    source(Writer, Seq + 500).
