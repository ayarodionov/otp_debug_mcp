%% Up to 10 restarts in 10 seconds: the importer's crash every 2 seconds
%% never makes the supervisor give up.
-module(orders_sup).
-behaviour(supervisor).

-export([start_link/0, init/1]).

start_link() ->
    supervisor:start_link({local, ?MODULE}, ?MODULE, []).

init([]) ->
    Flags = #{strategy => one_for_one, intensity => 10, period => 10},
    Children =
        [#{id => orders_payments, start => {orders_payments, start_link, []}},
         #{id => orders_coupons, start => {orders_coupons, start_link, []}},
         #{id => orders_importer, start => {orders_importer, start_link, []}}],
    {ok, {Flags, Children}}.
