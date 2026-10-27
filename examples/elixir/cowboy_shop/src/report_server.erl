%% Renders sales reports, 300 ms each.
-module(report_server).
-behaviour(gen_server).
-export([start_link/0, render/1]).
-export([init/1, handle_call/3, handle_cast/2]).

start_link() -> gen_server:start_link({local, ?MODULE}, ?MODULE, [], []).

render(Id) -> gen_server:call(?MODULE, {render, Id}, infinity).

init([]) -> {ok, #{rendered => 0}}.

handle_call({render, Id}, _From, S = #{rendered := N}) ->
    timer:sleep(300),
    {reply, {ok, <<"%PDF report ", Id/binary>>}, S#{rendered := N + 1}}.

handle_cast(_Msg, S) -> {noreply, S}.
