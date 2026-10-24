%% Applies a customer's coupon code to an order every 300 ms. A code that
%% can't be read gives no discount, silently: the error is caught, and
%% nothing is logged.
-module(orders_coupons).
-behaviour(gen_server).

-export([start_link/0]).
-export([init/1, handle_call/3, handle_cast/2, handle_info/2]).

-define(CODES, [<<"SAVE10">>, <<"SAVE5">>, <<"SPRING-15">>, <<"SAVE20">>, <<"save15">>]).

start_link() ->
    gen_server:start_link({local, ?MODULE}, ?MODULE, [], []).

init([]) ->
    erlang:send_after(300, self(), apply),
    {ok, 0}.

handle_info(apply, N) ->
    Code = lists:nth(N rem length(?CODES) + 1, ?CODES),
    _Percent = try discount(Code) catch _:_ -> 0 end,
    erlang:send_after(300, self(), apply),
    {noreply, N + 1}.

%% The bug: only codes written exactly "SAVE<number>" are understood.
discount(<<"SAVE", Percent/binary>>) ->
    binary_to_integer(Percent).

handle_call(_Request, _From, State) -> {reply, ok, State}.
handle_cast(_Msg, State) -> {noreply, State}.
