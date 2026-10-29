%% The sales report: every price, exported.
-module(price_reports).
-export([export/0]).

export() ->
    shackle:call(prices, export, 5000).
