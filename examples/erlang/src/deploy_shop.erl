%% deploy_erl: a fix deployed but never loaded, and a process left in old
%% code. discounts gives 5% off; the fix for 10% was compiled into
%% deploy/ebin after the node started (run.sh does that), but nothing
%% loaded it. And heartbeat was hot-loaded (run.sh does what l(heartbeat)
%% in a remote shell does) while its process loops, calling itself
%% locally.
-module(deploy_shop).
-export([start/0, orders/0]).

start() ->
    {ok, _} = discounts:start_link(),
    ok = heartbeat:start(),
    spawn(?MODULE, orders, []),
    ok.

%% An order every second; each takes the discount.
orders() ->
    register(deploy_orders, self()),
    Loop = fun L(N) ->
        _ = discounts:apply(100 + N rem 50),
        timer:sleep(1000),
        L(N + 1)
    end,
    Loop(1).
