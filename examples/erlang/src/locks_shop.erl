%% A shop that locks up. stock and pricing are gen_servers that call each
%% other:
%%
%% - stock reserves items for shoppers, and for each reservation asks
%%   pricing for the item's price, after checking its warehouses (20 ms).
%% - pricing refreshes its prices every 3 seconds, and asks stock for each
%%   item's level to do so.
%%
%% Both calls wait forever (infinity). The first refresh that starts while
%% stock is in a reservation deadlocks them: stock waits on pricing, which
%% waits on stock. 20 shoppers keep stock busy, so that happens within
%% seconds; then their calls time out after 5 seconds, again and again.
-module(locks_shop).
-export([start/0]).

start() ->
    {ok, _} = locks_stock:start(),
    {ok, _} = locks_pricing:start(),
    [spawn(fun() -> shopper(N) end) || N <- lists:seq(1, 20)],
    ok.

shopper(N) ->
    _ = (catch gen_server:call(locks_stock, {reserve, N rem 5}, 5000)),
    timer:sleep(200),
    shopper(N).
