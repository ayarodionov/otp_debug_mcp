%% Connects to the payment provider a second after it starts, parsing the
%% port from its URL. The URL is malformed, so it crashes every time, and
%% its supervisor restarts it, about once a second.
-module(payments_gateway).
-behaviour(gen_server).

-export([start_link/0]).
-export([init/1, handle_call/3, handle_cast/2, handle_info/2]).

start_link() ->
    gen_server:start_link({local, ?MODULE}, ?MODULE, [], []).

init([]) ->
    erlang:send_after(1000, self(), connect),
    {ok, #{url => os:getenv("GATEWAY_URL", "https://pay.example.com:443x/v2")}}.

handle_call(_Req, _From, State) ->
    {reply, ok, State}.

handle_cast(_Msg, State) ->
    {noreply, State}.

handle_info(connect, #{url := Url} = State) ->
    {match, [Port]} = re:run(Url, ":(\\w+)/", [{capture, all_but_first, list}]),
    %% The bug: "443x" isn't a port, so list_to_integer/1 raises badarg.
    {noreply, State#{port => list_to_integer(Port)}}.
