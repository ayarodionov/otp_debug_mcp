%% dist_a and dist_b: dist_a's catalog process sends the whole catalog,
%% about 2 MB, to the mirror on dist_b ten times a second, where a change
%% would do. dist_a's checkout calls dist_b's stock server for each order
%% over the same connection.
-module(dist_shop).
-export([start_a/1, start_b/0, catalog/1, mirror/0, checkout/1]).

start_b() ->
    register(mirror, spawn(?MODULE, mirror, [])),
    {ok, _} = dist_stock:start_link(),
    ok.

start_a(B) ->
    pong = net_adm:ping(B),
    register(catalog, spawn(?MODULE, catalog, [B])),
    register(checkout, spawn(?MODULE, checkout, [B])),
    ok.

catalog(B) ->
    Items = [{Id, <<"product ", (integer_to_binary(Id))/binary>>, Id rem 100, lists:seq(1, 20)}
             || Id <- lists:seq(1, 40000)],
    Loop = fun L(V) ->
        {mirror, B} ! {catalog, V, Items},
        timer:sleep(100),
        L(V + 1)
    end,
    Loop(1).

mirror() ->
    receive
        {catalog, _Version, _Items} -> mirror()
    end.

checkout(B) ->
    _ = gen_server:call({dist_stock, B}, {reserve, rand:uniform(1000)}),
    timer:sleep(50),
    checkout(B).
