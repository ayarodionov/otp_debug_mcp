-module(rates).
-behaviour(gen_server).
-export([start_link/0, clients/0, init/1, handle_call/3, handle_cast/2]).

start_link() -> gen_server:start_link({local, rates}, ?MODULE, [], []).

init([]) -> {ok, #{rate => 1.0}}.

handle_call(sum, _From, S) ->
    {reply, 42, S};
handle_call(refresh, _From, S) ->
    timer:sleep(200),
    Rate = gen_server:call(tally, rate),
    {reply, ok, S#{rate := Rate}}.

handle_cast(_, S) -> {noreply, S}.

%% Two clients: the report page and a refresh timer.
clients() ->
    Loop = fun(Server, Req, Every) ->
        spawn_link(fun L() ->
            catch gen_server:call(Server, Req),
            timer:sleep(Every),
            L()
        end)
    end,
    Loop(tally, get_total, 1500),
    Pid = Loop(rates, refresh, 2300),
    {ok, Pid}.
