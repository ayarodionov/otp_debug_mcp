%% A session store with two leaks. Every login makes an atom from the
%% session id (atoms are never freed, and the atom table has a limit) and
%% an ETS row that is never deleted. Simulated traffic logs in about 500
%% users a second.
-module(sessions).
-behaviour(gen_server).

-export([start/0, start_link/0, login/1]).
-export([init/1, handle_call/3, handle_cast/2]).

start() ->
    {ok, _} = start_link(),
    spawn(fun traffic/0),
    ok.

start_link() ->
    gen_server:start_link({local, ?MODULE}, ?MODULE, [], []).

login(UserId) ->
    gen_server:call(?MODULE, {login, UserId}).

init([]) ->
    {ok, ets:new(sessions, [named_table, set, protected])}.

handle_call({login, UserId}, _From, Table) ->
    Id = integer_to_list(UserId) ++ "_" ++ integer_to_list(erlang:unique_integer([positive])),
    %% The bugs: an atom per session, and rows nobody ever deletes.
    Session = list_to_atom("session_" ++ Id),
    ets:insert(Table, {Session, UserId, erlang:system_time(second)}),
    {reply, Session, Table}.

handle_cast(_Msg, Table) ->
    {noreply, Table}.

traffic() ->
    _ = login(rand:uniform(10000)),
    timer:sleep(2),
    traffic().
