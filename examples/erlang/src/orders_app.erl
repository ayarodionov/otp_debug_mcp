%% An orders service that keeps working while it fails, so only its logs
%% show what goes wrong:
%%
%% - At start, it can't read its pricing rules, logs an error once, and
%%   carries on with list prices: that error is only in its log file.
%% - orders_importer imports a batch of order lines every 2 seconds; one
%%   line has "n/a" for a quantity, so every import crashes it. Its
%%   supervisor restarts it each time, under its restart limit.
%% - orders_payments charges an order every 700 ms; the provider is often
%%   slow, which it logs as a warning, and sometimes times out, an error.
-module(orders_app).
-behaviour(application).

-export([start/2, stop/1]).

start(_Type, _Args) ->
    {ok, File} = application:get_env(orders, log_file),
    ok = logger:add_handler(orders_file, logger_std_h, #{config => #{file => File}}),
    case file:read_file("priv/pricing_rules.csv") of
        {ok, _} -> ok;
        {error, Reason} ->
            logger:error("pricing rules: couldn't read priv/pricing_rules.csv (~p); "
                         "every order is charged its list price", [Reason])
    end,
    orders_sup:start_link().

stop(_State) ->
    ok.
