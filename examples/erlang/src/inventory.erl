%% The shop's inventory: one gen_server holding the stock of every
%% product, as a map.
%%
%% - 20 shop processes reserve items, each every 50 ms, with
%%   gen_server:call(inventory, {reserve, Sku, Qty}): a map update;
%% - the warehouse dashboard asks for a stock report every 700 ms,
%%   which goes through every product and takes about 500 ms;
%% - every reservation is also recorded, with a cast, in an audit trail.
-module(inventory).
-behaviour(gen_server).

-export([start/0, reserve/2, stock_report/0]).
-export([init/1, handle_call/3, handle_cast/2, handle_info/2]).

start() ->
    {ok, _} = gen_server:start({local, ?MODULE}, ?MODULE, [], []),
    [spawn(fun() -> shop(I) end) || I <- lists:seq(1, 20)],
    spawn(fun dashboard/0),
    ok.

reserve(Sku, Qty) ->
    gen_server:call(?MODULE, {reserve, Sku, Qty}, 10000).

stock_report() ->
    gen_server:call(?MODULE, stock_report, 10000).

init([]) ->
    Stock = maps:from_list([{Sku, 1000000} || Sku <- lists:seq(1, 20000)]),
    {ok, #{stock => Stock, audit => []}}.

handle_call({reserve, Sku, Qty}, _From, #{stock := Stock} = State) ->
    case maps:get(Sku, Stock) of
        N when N >= Qty ->
            gen_server:cast(?MODULE, {audit, Sku, Qty}),
            {reply, ok, State#{stock := Stock#{Sku := N - Qty}}};
        _ ->
            {reply, {error, out_of_stock}, State}
    end;
handle_call(stock_report, _From, #{stock := Stock} = State) ->
    {reply, report(Stock), State}.

handle_cast({audit, Sku, Qty}, #{audit := Audit} = State) ->
    {noreply, State#{audit := lists:sublist([{Sku, Qty} | Audit], 1000)}}.

handle_info(_, State) ->
    {noreply, State}.

%% Every product's stock, valued and sorted: about half a second.
report(Stock) ->
    Valued = [{Sku, N, value(Sku, N)} || {Sku, N} <- maps:to_list(Stock)],
    lists:sublist(lists:reverse(lists:keysort(3, Valued)), 20).

value(Sku, N) ->
    lists:foldl(fun(I, Acc) -> Acc + (Sku * I) rem 7 end, N, lists:seq(1, 4000)).

shop(I) ->
    reserve(rand:uniform(20000), 1 + I rem 3),
    timer:sleep(50),
    shop(I).

dashboard() ->
    stock_report(),
    timer:sleep(700),
    dashboard().
