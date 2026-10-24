%% Reserves items, asking pricing for each item's price.
-module(locks_stock).
-behaviour(gen_server).

-export([start/0]).
-export([init/1, handle_call/3, handle_cast/2]).

start() ->
    gen_server:start({local, locks_stock}, ?MODULE, [], []).

init([]) ->
    {ok, #{0 => 40, 1 => 12, 2 => 7, 3 => 30, 4 => 3}}.

handle_call({reserve, Item}, _From, Levels) ->
    timer:sleep(20),
    Price = gen_server:call(locks_pricing, {price, Item}, infinity),
    {reply, {ok, Price}, Levels#{Item := maps:get(Item, Levels) - 1}};
handle_call({level, Item}, _From, Levels) ->
    {reply, maps:get(Item, Levels), Levels}.

handle_cast(_Msg, Levels) -> {noreply, Levels}.
