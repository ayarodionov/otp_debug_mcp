%% A shop that prices its products through a shackle pool, prices, to a
%% pricing backend (price_backend, port 8097, here in the same node).
-module(shackle_shop).
-behaviour(application).
-behaviour(supervisor).
-export([start/2, stop/1, init/1, traffic/0]).

start(_Type, _Args) ->
    {ok, Sup} = supervisor:start_link({local, shackle_shop_sup}, ?MODULE, []),
    ok = price_backend:start(8097),
    ok = shackle_pool:start(prices, price_client,
                            [{port, 8097}, {socket_options, [binary]}],
                            [{pool_size, 4}, {backlog_size, 16}]),
    {ok, Sup}.

stop(_) -> ok.

init([]) -> {ok, {{one_for_one, 5, 10}, []}}.

%% 20 shoppers looking up prices, and the nightly report, every second.
traffic() ->
    [spawn(fun shopper/0) || _ <- lists:seq(1, 20)],
    spawn(fun reports/0),
    ok.

shopper() ->
    _ = price_api:lookup(rand:uniform(1000)),
    timer:sleep(50),
    shopper().

reports() ->
    _ = price_reports:export(),
    timer:sleep(200),
    reports().
