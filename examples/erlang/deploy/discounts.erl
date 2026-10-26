-module(discounts).
-behaviour(gen_server).
-export([start_link/0, apply/1, init/1, handle_call/3, handle_cast/2]).

%% The fix: 10% off. The node runs the version built without it.
-ifdef(NEW_RATE).
-define(PERCENT, 10).
-else.
-define(PERCENT, 5).
-endif.

start_link() -> gen_server:start_link({local, discounts}, ?MODULE, [], []).

apply(Amount) -> gen_server:call(discounts, {apply, Amount}).

init([]) -> {ok, #{}}.

handle_call({apply, Amount}, _From, S) ->
    {reply, Amount - Amount * ?PERCENT div 100, S}.

handle_cast(_, S) -> {noreply, S}.
