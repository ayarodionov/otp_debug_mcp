{application, payments,
 [{description, "Payments demo in LFE, whose gateway is in a crash loop"},
  {vsn, "1.0.0"},
  {modules, ['payments-app', 'payments-sup', 'payments-gateway', 'payments-ledger']},
  {registered, ['payments-sup', 'payments-gateway', 'payments-ledger']},
  {applications, [kernel, stdlib]},
  {mod, {'payments-app', []}}]}.
