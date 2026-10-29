%% A shop on Mnesia: products with their stock, the orders placed, and
%% the day's stats. 20 shoppers place orders, each a transaction.
-module(mnesia_shop).
-export([start/0, place_order/2]).

-record(product, {sku, stock}).
-record(stats, {key, orders}).
-record(order, {id, sku, qty}).

start() ->
    ok = application:set_env(mnesia, dir, "/tmp/mnesia_shop_" ++ atom_to_list(node())),
    ok = mnesia:start(),
    {atomic, ok} = mnesia:create_table(product, [{attributes, record_info(fields, product)}]),
    {atomic, ok} = mnesia:create_table(stats, [{attributes, record_info(fields, stats)}]),
    {atomic, ok} = mnesia:create_table(order, [{attributes, record_info(fields, order)}]),
    [ok = mnesia:dirty_write(#product{sku = Sku, stock = 1000000}) || Sku <- lists:seq(1, 100)],
    ok = mnesia:dirty_write(#stats{key = orders_today, orders = 0}),
    [spawn(fun shopper/0) || _ <- lists:seq(1, 20)],
    ok.

shopper() ->
    _ = place_order(rand:uniform(100), 1),
    timer:sleep(20),
    shopper().

%% An order: the stock taken, the day's count updated, the order recorded,
%% once the payment provider's fraud check has passed.
place_order(Sku, Qty) ->
    mnesia:transaction(
      fun() ->
              [#stats{orders = N} = Stats] = mnesia:read(stats, orders_today, write),
              [#product{stock = Stock} = Product] = mnesia:read(product, Sku, write),
              ok = fraud:check(Sku, Qty),
              ok = mnesia:write(Product#product{stock = Stock - Qty}),
              ok = mnesia:write(Stats#stats{orders = N + 1}),
              mnesia:write(#order{id = make_ref(), sku = Sku, qty = Qty})
      end).
