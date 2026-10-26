%% A partition's carts.
-module(shop_vnode).
-behaviour(riak_core_vnode).
-export([start_vnode/1, init/1, handle_command/3, handle_coverage/4, handle_exit/3,
         handoff_starting/2, handoff_cancelled/1, handoff_finished/2,
         handle_handoff_command/3, handle_handoff_data/2, encode_handoff_item/2,
         is_empty/1, terminate/2, delete/1, handle_overload_command/3, handle_overload_info/2]).

start_vnode(I) -> riak_core_vnode_master:get_vnode_pid(I, ?MODULE).

init([Partition]) -> {ok, #{partition => Partition, data => #{}}}.

%% Adding an item checks the cart's stock first: 5 ms.
handle_command({add, Cart, Item}, _Sender, S = #{data := D}) ->
    timer:sleep(5),
    {reply, ok, S#{data := D#{Cart => [Item | maps:get(Cart, D, [])]}}};
handle_command({get, Cart}, _Sender, S = #{data := D}) -> {reply, maps:find(Cart, D), S}.

handle_handoff_command(_Req, _Sender, S) -> {noreply, S}.

handoff_starting(_, S) -> {true, S}.
handoff_cancelled(S) -> {ok, S}.
handoff_finished(_, S) -> {ok, S}.
handle_handoff_data(Bin, S = #{data := D}) ->
    {K, V} = binary_to_term(Bin), {reply, ok, S#{data := D#{K => V}}}.
encode_handoff_item(K, V) -> term_to_binary({K, V}).
is_empty(S = #{data := D}) -> {map_size(D) =:= 0, S}.
delete(S) -> {ok, S#{data := #{}}}.
handle_coverage(_Req, _KeySpaces, _Sender, S) -> {stop, not_implemented, S}.
handle_exit(_Pid, _Reason, S) -> {noreply, S}.
terminate(_Reason, _S) -> ok.
handle_overload_command(_, _, _) -> ok.
handle_overload_info(_, _) -> ok.
