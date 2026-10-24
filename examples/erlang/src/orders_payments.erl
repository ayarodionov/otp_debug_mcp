%% Charges an order every 700 ms through a payment provider that takes
%% 50-950 ms, and times out one charge in ten.
-module(orders_payments).
-behaviour(gen_server).

-include_lib("kernel/include/logger.hrl").

-export([start_link/0]).
-export([init/1, handle_call/3, handle_cast/2, handle_info/2]).

start_link() ->
    gen_server:start_link({local, ?MODULE}, ?MODULE, [], []).

init([]) ->
    erlang:send_after(700, self(), charge),
    {ok, 2000}.

handle_info(charge, Order) ->
    charge(Order, rand:uniform(900) + 50, rand:uniform(10)),
    erlang:send_after(700, self(), charge),
    {noreply, Order + 1}.

charge(Order, _Ms, 1) ->
    ?LOG_ERROR("payment for order ~p failed: ~p", [Order, {provider, timeout}]);
charge(Order, Ms, _) when Ms > 500 ->
    ?LOG_WARNING("payment provider slow: ~p ms for order ~p", [Ms, Order]);
charge(_Order, _Ms, _) ->
    ok.

handle_call(_Request, _From, State) -> {reply, ok, State}.
handle_cast(_Msg, State) -> {noreply, State}.
