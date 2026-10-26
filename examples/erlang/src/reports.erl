%% reports_erl: report workers that spend most of their CPU collecting
%% garbage. Each report lists every sale of the day as a tuple, sorts the
%% list by price and adds the prices up: two lists of 100,000 tuples made
%% and dropped for one number. Two workers do it all the time.
-module(reports).
-export([start/0, worker/1]).

start() ->
    [spawn(?MODULE, worker, [I]) || I <- [1, 2]],
    ok.

worker(I) ->
    register(list_to_atom("report_worker_" ++ integer_to_list(I)), self()),
    loop(I).

loop(I) ->
    _Total = daily_total(I),
    loop(I).

daily_total(Seed) ->
    Sales = [{Item, Qty, Qty * 3} || Item <- lists:seq(1, 100000), Qty <- [Item rem 7 + Seed]],
    ByPrice = lists:keysort(3, Sales),
    lists:foldl(fun({_, _, Price}, Sum) -> Sum + Price end, 0, ByPrice).
