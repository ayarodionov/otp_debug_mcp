%% A partition's wishlists, each a riak_dt set (an ORSWOT), merged when a
%% partition is handed off.
-module(wishlist_vnode).
-behaviour(riak_core_vnode).
-export([start_vnode/1, init/1, handle_command/3, handle_coverage/4, handle_exit/3,
         handoff_starting/2, handoff_cancelled/1, handoff_finished/2,
         handle_handoff_command/3, handle_handoff_data/2, encode_handoff_item/2,
         is_empty/1, terminate/2, delete/1, handle_overload_command/3, handle_overload_info/2]).

-include_lib("riak_core/include/riak_core_vnode.hrl").

start_vnode(I) -> riak_core_vnode_master:get_vnode_pid(I, ?MODULE).

init([Partition]) -> {ok, #{partition => Partition, lists => #{}}}.

handle_command({add, List, Item, Actor}, _Sender, S = #{lists := L}) ->
    {ok, Set} = riak_dt_orswot:update({add, Item}, Actor, maps:get(List, L, riak_dt_orswot:new())),
    {reply, ok, S#{lists := L#{List => Set}}};
handle_command({get, List}, _Sender, S = #{lists := L}) ->
    {reply, riak_dt_orswot:value(maps:get(List, L, riak_dt_orswot:new())), S}.

handle_handoff_command(#riak_core_fold_req_v2{foldfun = Fun, acc0 = Acc0}, _Sender, S = #{lists := L}) ->
    {reply, maps:fold(Fun, Acc0, L), S};
handle_handoff_command(_Req, _Sender, S) -> {noreply, S}.

handoff_starting(_, S) -> {true, S}.
handoff_cancelled(S) -> {ok, S}.
handoff_finished(_, S) -> {ok, S}.
handle_handoff_data(Bin, S = #{lists := L}) ->
    {K, Set} = binary_to_term(Bin),
    Merged = riak_dt_orswot:merge(Set, maps:get(K, L, riak_dt_orswot:new())),
    {reply, ok, S#{lists := L#{K => Merged}}}.
encode_handoff_item(K, Set) -> term_to_binary({K, Set}).
is_empty(S = #{lists := L}) -> {map_size(L) =:= 0, S}.
delete(S) -> {ok, S#{lists := #{}}}.
handle_coverage(_Req, _KeySpaces, _Sender, S) -> {stop, not_implemented, S}.
handle_exit(_Pid, _Reason, S) -> {noreply, S}.
terminate(_Reason, _S) -> ok.
handle_overload_command(_, _, _) -> ok.
handle_overload_info(_, _) -> ok.
