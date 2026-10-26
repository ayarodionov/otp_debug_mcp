-module(dist_stock).
-behaviour(gen_server).
-export([start_link/0, init/1, handle_call/3, handle_cast/2]).

start_link() -> gen_server:start_link({local, dist_stock}, ?MODULE, [], []).

init([]) -> {ok, #{}}.

handle_call({reserve, Item}, _From, S) -> {reply, {ok, Item}, S}.

handle_cast(_, S) -> {noreply, S}.
