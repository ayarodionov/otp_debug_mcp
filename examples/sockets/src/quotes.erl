%% A quotes service and its neighbours, all on 127.0.0.1 in one node:
%%
%% - the pricing backend (port 7001) answers a line, "QUOTE <sku>", with
%%   a price, in microseconds; the quote frontend keeps 4 connections
%%   to it and writes each request as the protocol's header, "QUOTE ",
%%   and then the sku: two small writes, with gen_tcp's defaults
%%   (nodelay false);
%% - the metrics collector (port 7002) reads its agents' lines with
%%   {active, true} and stores each one, a millisecond's work; its agent
%%   sends a few thousand lines a second;
%% - the nightly export (port 7003) streams the price list to the
%%   warehouse, whose loader reads a kilobyte a second, with
%%   send_timeout left at infinity.
%%
%% quotes:latency() gives the last quotes' latency.
-module(quotes).

-export([start/0, latency/0]).

start() ->
    Parent = self(),
    spawn(fun() ->
        register(quotes, self()),
        ets:new(quote_latency, [named_table, public, ordered_set]),
        listen(7001, fun pricing/1),
        listen(7002, fun collector/1),
        listen(7003, fun warehouse/1),
        [spawn(fun() -> frontend(I) end) || I <- lists:seq(1, 4)],
        spawn(fun agent/0),
        spawn(fun exporter/0),
        Parent ! started,
        receive stop -> ok end
    end),
    receive started -> ok after 10000 -> timeout end.

listen(Port, Handler) ->
    {ok, L} = gen_tcp:listen(Port, [binary, {ip, {127, 0, 0, 1}}, {active, false},
                                    {packet, line}, {reuseaddr, true}]),
    spawn(fun() -> accept(L, Handler) end).

accept(L, Handler) ->
    {ok, S} = gen_tcp:accept(L),
    Pid = spawn(fun() -> receive go -> Handler(S) end end),
    ok = gen_tcp:controlling_process(S, Pid),
    Pid ! go,
    accept(L, Handler).

%% The pricing backend: one line in, one line out.
pricing(S) ->
    case gen_tcp:recv(S, 0) of
        {ok, <<"QUOTE ", Sku/binary>>} ->
            Price = 100 + erlang:phash2(Sku, 9900),
            ok = gen_tcp:send(S, [integer_to_binary(Price), $\n]),
            pricing(S);
        _ ->
            ok
    end.

frontend(I) ->
    {ok, S} = gen_tcp:connect({127, 0, 0, 1}, 7001, [binary, {active, false}, {packet, line}]),
    quote(S, I, 0).

quote(S, I, N) ->
    T0 = erlang:monotonic_time(microsecond),
    ok = gen_tcp:send(S, <<"QUOTE ">>),
    ok = gen_tcp:send(S, [integer_to_binary(I * 100000 + N), $\n]),
    {ok, _Price} = gen_tcp:recv(S, 0),
    Took = erlang:monotonic_time(microsecond) - T0,
    ets:insert(quote_latency, {{N rem 2000, I}, Took}),
    timer:sleep(5),
    quote(S, I, N + 1).

%% The metrics collector: each line takes a millisecond to store.
collector(S) ->
    ok = inet:setopts(S, [{active, true}]),
    collect(S).

collect(S) ->
    receive
        {tcp, S, _Line} ->
            timer:sleep(1),
            collect(S);
        {tcp_closed, S} ->
            ok
    end.

agent() ->
    {ok, S} = gen_tcp:connect({127, 0, 0, 1}, 7002, [binary, {active, false}, {nodelay, true}]),
    agent(S, 0).

agent(S, N) ->
    Line = io_lib:format("cpu.load host=web-~b value=~b~n", [N rem 40, N rem 100]),
    ok = gen_tcp:send(S, Line),
    case N rem 10 of
        0 -> timer:sleep(3);
        _ -> ok
    end,
    agent(S, N + 1).

%% The warehouse's loader: a kilobyte a second.
warehouse(S) ->
    ok = inet:setopts(S, [{packet, raw}]),
    load(S).

load(S) ->
    case gen_tcp:recv(S, 1024) of
        {ok, _} ->
            timer:sleep(1000),
            load(S);
        _ ->
            ok
    end.

exporter() ->
    {ok, S} = gen_tcp:connect({127, 0, 0, 1}, 7003, [binary, {active, false}]),
    Chunk = binary:copy(<<"sku,price,stock\n">>, 4096),
    export(S, Chunk).

export(S, Chunk) ->
    ok = gen_tcp:send(S, Chunk),
    export(S, Chunk).

%% The last quotes' latency: p50, p99 and the maximum, in ms.
latency() ->
    case lists:sort([T || {_, T} <- ets:tab2list(quote_latency)]) of
        [] -> none;
        L ->
            P = fun(Q) -> lists:nth(max(1, round(Q * length(L))), L) / 1000 end,
            #{quotes => length(L), p50_ms => P(0.5), p99_ms => P(0.99), max_ms => lists:last(L) / 1000}
    end.
