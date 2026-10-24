%% A worker that calls Fun every Interval ms: pricing calls the checksum
%% NIF, ingest the parse NIF.
-module(native_shop_worker).
-behaviour(gen_server).
-export([start_link/3]).
-export([init/1, handle_call/3, handle_cast/2, handle_info/2]).

start_link(Name, Interval, Fun) ->
    gen_server:start_link({local, Name}, ?MODULE, {Interval, Fun}, []).

init({Interval, Fun}) ->
    erlang:send_after(Interval, self(), work),
    {ok, #{interval => Interval, work => Fun, done => 0}}.

handle_call(done, _From, #{done := Done} = State) -> {reply, Done, State}.
handle_cast(_Msg, State) -> {noreply, State}.

handle_info(work, #{interval := Interval, work := Fun, done := Done} = State) ->
    _ = Fun(),
    erlang:send_after(Interval, self(), work),
    {noreply, State#{done := Done + 1}}.
