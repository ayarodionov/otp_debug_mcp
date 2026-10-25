%% Erlang book, chapter 2, section 4.1: a receive loop with no catch-all.
%% The checkout adds to the counter; refunds, added later, send {sub, X}.
-module(counter).
-export([start/0]).

start() ->
    Pid = spawn(fun() -> loop(0) end),
    register(counter, Pid),
    spawn(fun() -> sales(0) end),
    spawn(fun() -> refunds() end),
    ok.

loop(State) ->
    receive
        {add, X}   -> loop(State + X);
        {get, From} -> From ! State, loop(State)
    end.

sales(N) ->
    counter ! {add, 10},
    N rem 50 =:= 0 andalso begin counter ! {get, self()}, receive _ -> ok end end,
    timer:sleep(5),
    sales(N + 1).

refunds() ->
    counter ! {sub, 10},
    timer:sleep(20),
    refunds().
