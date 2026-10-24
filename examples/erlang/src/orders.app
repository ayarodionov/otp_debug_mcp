{application, orders,
 [{description, "Orders demo whose errors are only in its logs"},
  {vsn, "1.0.0"},
  {modules, [orders_app, orders_sup, orders_importer, orders_payments, orders_coupons]},
  {registered, [orders_sup, orders_importer, orders_payments, orders_coupons]},
  {applications, [kernel, stdlib]},
  {mod, {orders_app, []}},
  {env, [{log_file, "orders_erl.log"}]}]}.
