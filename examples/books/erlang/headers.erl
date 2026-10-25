%% Erlang book, chapter 3, section 4.3: keeping a small slice of a huge binary.
%% Each request's body is 1 MB; the server keeps a 512-byte header slice
%% for each of the last 200 sessions.
-module(headers).
-behaviour(gen_server).
-export([start/0, init/1, handle_call/3, handle_cast/2, handle_info/2]).

start() ->
    {ok, Pid} = gen_server:start({local, headers}, ?MODULE, [], []),
    spawn(fun() -> requests(Pid, 0) end),
    ok.

requests(Pid, N) ->
    Body = <<(rand:bytes(32))/binary, (binary:copy(<<"h">>, 512))/binary,
             (binary:copy(<<"b">>, 1024 * 1024))/binary>>,
    Pid ! {http_body, N rem 200, Body},
    timer:sleep(50),
    requests(Pid, N + 1).

init([]) -> {ok, #{}}.

handle_info({http_body, Session, Body}, State) ->
    <<_:32/binary, Header:512/binary, _/binary>> = Body,
    {noreply, State#{Session => Header}}.

handle_call(_, _, S) -> {reply, ok, S}.
handle_cast(_, S) -> {noreply, S}.
