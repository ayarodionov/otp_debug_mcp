%% A healthy sibling of the gateway.
-module(payments_ledger).
-behaviour(gen_server).

-export([start_link/0]).
-export([init/1, handle_call/3, handle_cast/2]).

start_link() ->
    gen_server:start_link({local, ?MODULE}, ?MODULE, #{}, []).

init(Entries) ->
    {ok, Entries}.

handle_call(entries, _From, Entries) ->
    {reply, Entries, Entries}.

handle_cast(_Msg, Entries) ->
    {noreply, Entries}.
