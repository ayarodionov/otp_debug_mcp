-module(heartbeat).
-export([start/0]).

%% Every second, the time of the last beat. The loop calls itself
%% locally, as plain receive loops do: a newer version of the module is
%% never picked up.
start() ->
    register(heartbeat, spawn(fun() -> loop(0) end)),
    ok.

loop(N) ->
    receive
        stop -> ok
    after 1000 ->
        loop(N + 1)
    end.
