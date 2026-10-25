%% Erlang book, chapter 5, section 4.6: two servers calling each other.
%% tally:get_total calls rates:sum; rates:refresh calls tally:rate. Each
%% works alone; when the two requests overlap, both wait for the other.
-module(tally).
-behaviour(gen_server).
-export([start/0, start_link/0, init/1, handle_call/3, handle_cast/2]).

start() ->
    spawn(fun() ->
        {ok, _} = supervisor:start_link({local, tally_sup}, ?MODULE, sup),
        receive never -> ok end
    end),
    ok.

start_link() -> gen_server:start_link({local, tally}, ?MODULE, [], []).

init(sup) ->
    {ok, {#{intensity => 100, period => 60},
          [#{id => tally, start => {tally, start_link, []}},
           #{id => rates, start => {rates, start_link, []}},
           #{id => clients, start => {rates, clients, []}}]}};
init([]) -> {ok, #{}}.

handle_call(get_total, _From, S) ->
    timer:sleep(200),
    Total = gen_server:call(rates, sum),
    {reply, Total, S};
handle_call(rate, _From, S) ->
    {reply, 1.2, S}.

handle_cast(_, S) -> {noreply, S}.
