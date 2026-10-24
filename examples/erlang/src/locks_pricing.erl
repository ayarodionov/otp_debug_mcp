%% Prices items, and every 3 seconds refreshes them from stock levels.
-module(locks_pricing).
-behaviour(gen_server).

-export([start/0]).
-export([init/1, handle_call/3, handle_cast/2, handle_info/2]).

start() ->
    gen_server:start({local, locks_pricing}, ?MODULE, [], []).

init([]) ->
    erlang:send_after(3000, self(), refresh),
    {ok, #{}}.

handle_call({price, Item}, _From, Prices) ->
    {reply, maps:get(Item, Prices, 10.0), Prices}.

handle_info(refresh, _Prices) ->
    Prices = maps:from_list([{Item, price(gen_server:call(locks_stock, {level, Item}, infinity))}
                             || Item <- lists:seq(0, 4)]),
    erlang:send_after(3000, self(), refresh),
    {noreply, Prices}.

%% Scarcer items cost more.
price(Level) when Level < 10 -> 15.0;
price(_Level) -> 10.0.

handle_cast(_Msg, Prices) -> {noreply, Prices}.
