%% Prices for the shop's pages: they must come back within 100 ms.
-module(price_api).
-export([lookup/1]).

lookup(Sku) ->
    shackle:call(prices, {get, Sku}, 100).
