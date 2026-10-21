{application, payments,
 [{description, "Payments demo whose gateway is in a crash loop"},
  {vsn, "1.0.0"},
  {modules, [payments_app, payments_sup, payments_gateway, payments_ledger]},
  {registered, [payments_sup, payments_gateway, payments_ledger]},
  {applications, [kernel, stdlib]},
  {mod, {payments_app, []}}]}.
