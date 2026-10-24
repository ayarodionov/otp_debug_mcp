%% Imports a batch of order lines ("id;quantity;price") every 2 seconds.
-module(orders_importer).
-behaviour(gen_server).

-export([start_link/0]).
-export([init/1, handle_call/3, handle_cast/2, handle_info/2]).

-define(BATCH, [<<"1001;3;19.99">>, <<"1002;1;5.00">>, <<"1003;n/a;7.50">>, <<"1004;2;12.00">>]).

start_link() ->
    gen_server:start_link({local, ?MODULE}, ?MODULE, [], []).

init([]) ->
    erlang:send_after(2000, self(), import),
    {ok, #{imported => 0}}.

handle_info(import, #{imported := N} = State) ->
    Orders = [parse_line(Line) || Line <- ?BATCH],
    erlang:send_after(2000, self(), import),
    {noreply, State#{imported := N + length(Orders)}}.

%% The bug: a quantity that isn't a number crashes the whole import.
parse_line(Line) ->
    [Id, Quantity, Price] = binary:split(Line, <<";">>, [global]),
    #{id => binary_to_integer(Id),
      quantity => binary_to_integer(Quantity),
      price => binary_to_float(Price)}.

handle_call(_Request, _From, State) -> {reply, ok, State}.
handle_cast(_Msg, State) -> {noreply, State}.
