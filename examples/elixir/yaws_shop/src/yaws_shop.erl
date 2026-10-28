%% A shop's HTTP API on Yaws, embedded, port 8095: /api/products lists the
%% products, /api/cart shows the shopper's cart and recommendations.
-module(yaws_shop).
-behaviour(application).
-behaviour(supervisor).
-export([start/2, stop/1, init/1, traffic/0]).

start(_Type, _Args) ->
    {ok, Sup} = supervisor:start_link({local, yaws_shop_sup}, ?MODULE, []),
    ok = filelib:ensure_dir("log/"),
    Docroot = filename:join(code:priv_dir(yaws_shop), "www"),
    ok = yaws:start_embedded(Docroot,
                             [{port, 8095}, {listen, {0, 0, 0, 0}}, {servername, "shop"},
                              {appmods, [{"/api", shop_api}]}],
                             [{logdir, "log"}, {id, "shop"}],
                             "shop"),
    {ok, Sup}.

stop(_) -> ok.

init([]) -> {ok, {{one_for_one, 5, 10}, []}}.

%% The shop's clients: its mobile app, which keeps no cookies, 10 shoppers
%% looking at their carts.
traffic() ->
    [spawn(fun() -> client() end) || _ <- lists:seq(1, 10)],
    ok.

client() ->
    case gen_tcp:connect({127, 0, 0, 1}, 8095, [binary, {active, false}], 1000) of
        {ok, S} -> requests(S);
        _ -> ok
    end,
    timer:sleep(100),
    client().

requests(S) ->
    case gen_tcp:send(S, <<"GET /api/cart HTTP/1.1\r\nhost: shop\r\n\r\n">>) of
        ok ->
            case gen_tcp:recv(S, 0, 10000) of
                {ok, _} -> timer:sleep(200), requests(S);
                _ -> gen_tcp:close(S)
            end;
        _ ->
            gen_tcp:close(S)
    end.
