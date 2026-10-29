%% Price quotes for orders: each line priced from the catalog, and the
%% quote's text, line by line, with the total.
-module(quote).
-export([build/1, sample_order/1, catalog/0, start_reps/0]).

%% The catalog: 5000 products and their prices, as the pricing team
%% exports it.
catalog() ->
    [{Sku, 100 + (Sku * 37) rem 900} || Sku <- lists:seq(1, 5000)].

%% An order of N lines.
sample_order(N) ->
    {order, 42, [{1 + (I * 7919) rem 5000, 1 + I rem 5} || I <- lists:seq(1, N)]}.

build({order, Id, Lines}) ->
    Catalog = catalog(),
    {Text, Total} = price_lines(Lines, Catalog, 1, "", 0),
    {quote, Id, Total, Text}.

price_lines(Lines, Catalog, I, Text, Total) when I =< length(Lines) ->
    {Sku, Qty} = lists:nth(I, Lines),
    {Sku, Price} = lists:keyfind(Sku, 1, Catalog),
    Line = io_lib:format("~6w x~2w @ ~4w = ~7w~n", [Sku, Qty, Price, Qty * Price]),
    price_lines(Lines, Catalog, I + 1, Text ++ lists:flatten(Line), Total + Qty * Price);
price_lines(_Lines, _Catalog, _I, Text, Total) ->
    {Text, Total}.

%% Four sales reps, building quotes for big orders all day.
start_reps() ->
    [spawn(fun rep/0) || _ <- lists:seq(1, 4)],
    ok.

rep() ->
    _ = build(sample_order(3000)),
    rep().
