%% quote, tuned: the same quotes, built in one pass over the lines, with
%% the catalog in a map, and the text as an iolist flattened once.
-module(quote_fast).
-export([build/1]).

build({order, Id, Lines}) ->
    Prices = maps:from_list(quote:catalog()),
    {Parts, Total} = lists:foldl(
                       fun({Sku, Qty}, {Acc, Sum}) ->
                               Price = maps:get(Sku, Prices),
                               Line = io_lib:format("~6w x~2w @ ~4w = ~7w~n", [Sku, Qty, Price, Qty * Price]),
                               {[Line | Acc], Sum + Qty * Price}
                       end, {[], 0}, Lines),
    {quote, Id, Total, lists:flatten(lists:reverse(Parts))}.
