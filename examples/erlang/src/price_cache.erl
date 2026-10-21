%% A price cache that can't keep up. Each update takes 5 ms, so it handles
%% about 200 a second, while a producer casts 25,000 a second: the cache's
%% mailbox grows without bound, and anything that calls it waits behind it.
-module(price_cache).
-behaviour(gen_server).

-export([start/0, start_link/0, update/2, prices/0]).
-export([init/1, handle_call/3, handle_cast/2]).

%% Start the cache and its producer.
start() ->
    {ok, _} = start_link(),
    spawn(fun() -> produce(0) end),
    ok.

start_link() ->
    gen_server:start_link({local, ?MODULE}, ?MODULE, #{}, []).

update(Sku, Price) ->
    gen_server:cast(?MODULE, {update, Sku, Price}).

prices() ->
    gen_server:call(?MODULE, prices).

init(Prices) ->
    {ok, Prices}.

handle_call(prices, _From, Prices) ->
    {reply, Prices, Prices}.

handle_cast({update, Sku, Price}, Prices) ->
    %% The bug: slow work for every message, with nothing slowing the sender.
    timer:sleep(5),
    {noreply, Prices#{Sku => Price}}.

%% Fire-and-forget casts, about 25,000 a second (a pause every 100), so the
%% backlog grows fast but the demo doesn't eat all your memory at once.
produce(N) ->
    update(N rem 1000, N),
    case N rem 100 of
        0 -> timer:sleep(4);
        _ -> ok
    end,
    produce(N + 1).
