%% A pricing service, in a container limited to one CPU and 256 MB:
%%
%% - baskets come in bursts, 80 every quarter of a second (a shop's
%%   checkout batch), each priced on one of 8 workers in about 2 ms of
%%   CPU, and the service logs each one at debug;
%% - a health check, every 10 ms, which does nothing;
%% - a cache of price lists, loaded at start and growing as products are
%%   priced, is kept in an ETS table.
%%
%% It measures its own latency, the baskets' and the health check's (how
%% late it ran), and keeps the last minute's in pricing:latency().
-module(pricing).

-export([start/0, latency/0]).

start() ->
    Parent = self(),
    %% The tables' owner: the shell's -eval process ends once this returns.
    spawn(fun() ->
        register(pricing, self()),
        logger:set_primary_config(level, debug),
        ets:new(price_cache, [named_table, public, set]),
        ets:new(latency, [named_table, public, ordered_set]),
        %% The price lists, about 90 MB, and more as products are priced.
        [ets:insert(price_cache, {Sku, price_list(Sku)}) || Sku <- lists:seq(1, 9000)],
        Workers = [spawn(fun worker/0) || _ <- lists:seq(1, 8)],
        spawn(fun() -> requests(Workers, 0) end),
        spawn(fun() -> health(erlang:monotonic_time(microsecond)) end),
        spawn(fun() -> grow(9001) end),
        Parent ! started,
        receive stop -> ok end
    end),
    receive started -> ok after 60000 -> timeout end.

price_list(Sku) ->
    <<Sku:64, (crypto:strong_rand_bytes(10000))/binary>>.

requests(Workers, N) ->
    Now = erlang:monotonic_time(microsecond),
    [lists:nth(I rem length(Workers) + 1, Workers) ! {price, Now, I} || I <- lists:seq(N, N + 79)],
    timer:sleep(250),
    requests(Workers, N + 80).

%% A health check due every 10 ms: how late each one runs.
health(Due) ->
    timer:sleep(10),
    Now = erlang:monotonic_time(microsecond),
    ets:insert(latency, {{erlang:monotonic_time(millisecond), health, Now}, Now - Due - 10000}),
    health(Now).

worker() ->
    receive
        {price, Sent, N} ->
            Total = basket(N),
            logger:debug("priced basket ~p: ~p", [N, Total]),
            Took = erlang:monotonic_time(microsecond) - Sent,
            ets:insert(latency, {{erlang:monotonic_time(millisecond), basket, N}, Took}),
            worker()
    end.

%% About 2 ms of arithmetic.
basket(N) ->
    lists:foldl(fun(I, Acc) -> (Acc + I * N) rem 1000003 end, 0, lists:seq(1, 60000)).

%% New products are priced into the cache, half a megabyte a second,
%% up to 120 MB in all.
grow(Sku) when Sku < 12000 ->
    ets:insert(price_cache, {Sku, price_list(Sku)}),
    timer:sleep(20),
    grow(Sku + 1);
grow(_) ->
    ok.

%% The last minute's latencies, baskets' and health checks': p50, p99
%% and the maximum, in ms.
latency() ->
    Since = erlang:monotonic_time(millisecond) - 60000,
    ets:select_delete(latency, [{{{'$1', '_', '_'}, '_'}, [{'<', '$1', Since}], [true]}]),
    maps:from_list([{Kind, percentiles(lists:sort(ets:select(latency, [{{{'_', Kind, '_'}, '$1'}, [], ['$1']}])))}
                    || Kind <- [basket, health]]).

percentiles([]) -> none;
percentiles(L) ->
    P = fun(Q) -> lists:nth(max(1, round(Q * length(L))), L) / 1000 end,
    #{count => length(L), p50_ms => P(0.5), p99_ms => P(0.99), max_ms => lists:last(L) / 1000}.
