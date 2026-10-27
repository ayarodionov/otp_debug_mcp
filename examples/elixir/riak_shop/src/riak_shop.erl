%% A shop on riak_core: carts kept in shop_vnode, and wishlists, riak_dt
%% sets, in wishlist_vnode, one of each per partition of the ring, spread
%% over riak_a, riak_b and riak_c.
-module(riak_shop).
-behaviour(application).
-behaviour(supervisor).
-export([start/2, stop/1, init/1, add/2, cart/1, traffic/0, demo/2]).
-export([wish/2, wishlist/1, wishlist_traffic/0, wishlist_demo/1]).

start(_Type, _Args) ->
    {ok, Pid} = supervisor:start_link({local, riak_shop_sup}, ?MODULE, []),
    ok = riak_core:register([{vnode_module, shop_vnode}]),
    ok = riak_core:register([{vnode_module, wishlist_vnode}]),
    ok = riak_core_node_watcher:service_up(riak_shop, self()),
    {ok, Pid}.

stop(_) -> ok.

init([]) ->
    {ok, {{one_for_one, 5, 10},
          [{shop_vnode_master, {riak_core_vnode_master, start_link, [shop_vnode]},
            permanent, 5000, worker, [riak_core_vnode_master]},
           {wishlist_vnode_master, {riak_core_vnode_master, start_link, [wishlist_vnode]},
            permanent, 5000, worker, [riak_core_vnode_master]}]}}.

add(Cart, Item) -> command(Cart, {add, Cart, Item}).
cart(Cart) -> command(Cart, {get, Cart}).

command(Cart, Cmd) ->
    riak_core_vnode_master:sync_command(index_node(Cart), Cmd, shop_vnode_master, 5000).

index_node(Cart) -> index_node(<<"carts">>, Cart).

index_node(Bucket, Key) ->
    Idx = riak_core_util:chash_key({Bucket, term_to_binary(Key)}),
    [IndexNode] = riak_core_apl:get_apl(Idx, 1, riak_shop),
    IndexNode.

%% Shoppers adding items to their carts, and a flash sale: everyone adds
%% to the same shared cart, without waiting for an answer.
traffic() ->
    [spawn(fun() -> shopper(N) end) || N <- lists:seq(1, 20)],
    spawn(fun flash_sale/0),
    ok.

shopper(N) ->
    catch add({cart, N, rand:uniform(1000)}, {item, rand:uniform(100)}),
    timer:sleep(50),
    shopper(N).

flash_sale() ->
    riak_core_vnode_master:command(index_node(flash_sale), {add, flash_sale, {item, 1}},
                                   shop_vnode_master),
    timer:sleep(1),
    flash_sale().

%% The demo's setup, run on riak_a: riak_b and riak_c join, the plan is
%% committed and its handoffs run; then riak_c goes down, and the traffic
%% starts.
demo(B, C) ->
    wait(fun() ->
             lists:all(fun(N) -> is_pid(rpc:call(N, erlang, whereis, [riak_core_ring_manager])) end,
                       [node(), B, C])
         end),
    ok = rpc:call(B, riak_core, join, [node()]),
    ok = rpc:call(C, riak_core, join, [node()]),
    wait(fun() ->
             {ok, R} = riak_core_ring_manager:get_my_ring(),
             Joining = [N || {N, joining} <- riak_core_ring:all_member_status(R)],
             lists:sort(Joining) =:= lists:sort([B, C])
         end),
    {ok, _, _} = riak_core_claimant:plan(),
    ok = riak_core_claimant:commit(),
    wait(fun() ->
             {ok, R} = riak_core_ring_manager:get_my_ring(),
             riak_core_ring:pending_changes(R) =:= []
         end),
    rpc:call(C, init, stop, []),
    wait(fun() -> not lists:member(C, riak_core_node_watcher:nodes(riak_shop)) end),
    traffic().

%% Adding to a wishlist: each request runs in a process of its own, as a
%% web server's do, and the set is updated with the request's process as
%% its actor.
wish(List, Item) ->
    riak_core_vnode_master:sync_command(index_node(<<"wishlists">>, List),
                                        {add, List, Item, self()}, wishlist_vnode_master, 5000).

wishlist(List) ->
    riak_core_vnode_master:sync_command(index_node(<<"wishlists">>, List), {get, List},
                                        wishlist_vnode_master, 5000).

%% Shoppers adding to 20 wishlists, from a few dozen items each: a new
%% request process every time.
wishlist_traffic() ->
    [spawn(fun() -> wisher() end) || _ <- lists:seq(1, 10)],
    ok.

wisher() ->
    List = {wishlist, rand:uniform(20)},
    Item = {item, rand:uniform(30)},
    {_, Ref} = spawn_monitor(fun() -> catch wish(List, Item) end),
    receive {'DOWN', Ref, process, _, _} -> ok end,
    timer:sleep(5),
    wisher().

%% The wishlist demo's setup, run on riak_a: riak_b joins, the plan is
%% committed and its handoffs run; then the wishlist traffic starts.
wishlist_demo(B) ->
    wait(fun() -> is_pid(rpc:call(B, erlang, whereis, [riak_core_ring_manager])) end),
    ok = rpc:call(B, riak_core, join, [node()]),
    wait(fun() ->
             {ok, R} = riak_core_ring_manager:get_my_ring(),
             lists:member({B, joining}, riak_core_ring:all_member_status(R))
         end),
    {ok, _, _} = riak_core_claimant:plan(),
    ok = riak_core_claimant:commit(),
    wait(fun() ->
             {ok, R} = riak_core_ring_manager:get_my_ring(),
             riak_core_ring:pending_changes(R) =:= []
         end),
    wishlist_traffic().

wait(Done) ->
    case Done() of
        true -> ok;
        false -> timer:sleep(500), wait(Done)
    end.
