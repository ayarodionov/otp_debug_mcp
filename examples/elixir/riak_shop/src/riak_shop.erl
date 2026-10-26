%% A shop on riak_core: carts kept in shop_vnode, one per partition of
%% the ring, spread over riak_a, riak_b and riak_c.
-module(riak_shop).
-behaviour(application).
-behaviour(supervisor).
-export([start/2, stop/1, init/1, add/2, cart/1, traffic/0, demo/2]).

start(_Type, _Args) ->
    {ok, Pid} = supervisor:start_link({local, riak_shop_sup}, ?MODULE, []),
    ok = riak_core:register([{vnode_module, shop_vnode}]),
    ok = riak_core_node_watcher:service_up(riak_shop, self()),
    {ok, Pid}.

stop(_) -> ok.

init([]) ->
    {ok, {{one_for_one, 5, 10},
          [{shop_vnode_master, {riak_core_vnode_master, start_link, [shop_vnode]},
            permanent, 5000, worker, [riak_core_vnode_master]}]}}.

add(Cart, Item) -> command(Cart, {add, Cart, Item}).
cart(Cart) -> command(Cart, {get, Cart}).

command(Cart, Cmd) ->
    riak_core_vnode_master:sync_command(index_node(Cart), Cmd, shop_vnode_master, 5000).

index_node(Cart) ->
    Idx = riak_core_util:chash_key({<<"carts">>, term_to_binary(Cart)}),
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

wait(Done) ->
    case Done() of
        true -> ok;
        false -> timer:sleep(500), wait(Done)
    end.
