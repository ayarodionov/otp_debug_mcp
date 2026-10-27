%% A shop's HTTP API on Cowboy, port 8090: /products lists the products,
%% /reports/:id renders a sales report.
-module(cowboy_shop).
-behaviour(application).
-behaviour(supervisor).
-export([start/2, stop/1, init/1, traffic/0]).

start(_Type, _Args) ->
    {ok, Sup} = supervisor:start_link({local, cowboy_shop_sup}, ?MODULE, []),
    Dispatch = cowboy_router:compile([{'_', [{"/products", products_handler, []},
                                             {"/reports/:id", report_handler, []}]}]),
    {ok, _} = cowboy:start_clear(shop_http,
                                 #{socket_opts => [{port, 8090}],
                                   num_acceptors => 4, max_connections => 10},
                                 #{env => #{dispatch => Dispatch}}),
    {ok, Sup}.

stop(_) -> ok.

init([]) ->
    {ok, {{one_for_one, 5, 10},
          [{report_server, {report_server, start_link, []}, permanent, 5000, worker, [report_server]}]}}.

%% The shop's clients: 60 accountants asking for reports, 10 shoppers
%% browsing the products, each request on a new connection.
traffic() ->
    [spawn(fun() -> client(<<"/reports/", (integer_to_binary(N))/binary>>) end) || N <- lists:seq(1, 60)],
    timer:sleep(2000),
    [spawn(fun() -> client(<<"/products">>) end) || _ <- lists:seq(1, 10)],
    ok.

client(Path) ->
    case gen_tcp:connect({127, 0, 0, 1}, 8090, [binary, {active, false}], 1000) of
        {ok, S} ->
            _ = gen_tcp:send(S, [<<"GET ">>, Path, <<" HTTP/1.1\r\nhost: shop\r\nconnection: close\r\n\r\n">>]),
            _ = gen_tcp:recv(S, 0, 60000),
            gen_tcp:close(S);
        _ ->
            ok
    end,
    timer:sleep(200),
    client(Path).
