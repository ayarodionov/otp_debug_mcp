%% Up to 15 restarts in 10 seconds: lenient enough that the gateway's crash
%% loop, about one restart a second, never makes the supervisor give up.
-module(payments_sup).
-behaviour(supervisor).

-export([start_link/0, init/1]).

start_link() ->
    supervisor:start_link({local, ?MODULE}, ?MODULE, []).

init([]) ->
    Flags = #{strategy => one_for_one, intensity => 15, period => 10},
    Children =
        [#{id => payments_ledger, start => {payments_ledger, start_link, []}},
         #{id => payments_gateway, start => {payments_gateway, start_link, []}}],
    {ok, {Flags, Children}}.
