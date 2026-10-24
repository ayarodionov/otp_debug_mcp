%% A shop whose ports misbehave three ways:
%%
%% - ports_client opens a new TCP connection to the upstream for every
%%   request, 5 a second, and never closes it: sockets leak.
%% - ports_feed sends 64 KB to the upstream every 50 ms over one
%%   connection, but the upstream reads only 4 KB every 100 ms: data piles
%%   up in the socket, and the feed ends up suspended on a busy port.
%% - ports_thumbnailer starts an external program for every job, 2 a
%%   second, and never closes it: OS processes pile up. (The program is
%%   cat, standing in for a converter that reads its job on stdin; like
%%   one, it exits when its port closes, so stopping the node ends them.)
-module(ports_shop).
-export([start/0]).

start() ->
    {ok, Listen} = gen_tcp:listen(0, [binary, {active, false}, {reuseaddr, true}]),
    {ok, Port} = inet:port(Listen),
    register(ports_upstream, spawn(fun() -> accept(Listen) end)),
    gen_tcp:controlling_process(Listen, whereis(ports_upstream)),
    register(ports_client, spawn(fun() -> client(Port) end)),
    register(ports_feed, spawn(fun() -> feed(Port) end)),
    register(ports_thumbnailer, spawn(fun() -> thumbnailer(0) end)),
    ok.

%% The upstream: a reader per connection, 4 KB every 100 ms.
accept(Listen) ->
    {ok, Socket} = gen_tcp:accept(Listen),
    Reader = spawn(fun() -> receive go -> read_slowly(Socket) end end),
    ok = gen_tcp:controlling_process(Socket, Reader),
    Reader ! go,
    accept(Listen).

read_slowly(Socket) ->
    case gen_tcp:recv(Socket, 4096, 1000) of
        {error, closed} -> ok;
        _ -> timer:sleep(100), read_slowly(Socket)
    end.

%% The bug: a connection per request, never closed.
client(Port) ->
    {ok, _Socket} = gen_tcp:connect("127.0.0.1", Port, [binary, {active, false}]),
    timer:sleep(200),
    client(Port).

%% The bug: 64 KB every 50 ms into a connection read at 40 KB a second.
%% The port queues up to 8 MB before sends block.
feed(Port) ->
    {ok, Socket} = gen_tcp:connect("127.0.0.1", Port,
                                   [binary, {active, false}, {high_watermark, 8388608}]),
    Chunk = binary:copy(<<"price-update;">>, 5000),
    feed_loop(Socket, Chunk).

feed_loop(Socket, Chunk) ->
    ok = gen_tcp:send(Socket, Chunk),
    timer:sleep(50),
    feed_loop(Socket, Chunk).

%% The bug: an external program per job, never closed.
thumbnailer(N) ->
    _ = open_port({spawn, "cat"}, []),
    timer:sleep(500),
    thumbnailer(N + 1).
