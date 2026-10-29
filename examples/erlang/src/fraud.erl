%% The payment provider's fraud check: an HTTP call, about 30 ms.
-module(fraud).
-export([check/2]).

check(_Sku, _Qty) ->
    timer:sleep(30),
    ok.
