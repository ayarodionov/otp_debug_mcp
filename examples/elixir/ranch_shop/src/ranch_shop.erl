%% The shop's point-of-sale server: the tills in its stores connect to
%% port 5555 and speak a line protocol of its own (pos_protocol), on
%% Ranch: 4 acceptors, 25 connections each.
-module(ranch_shop).
-behaviour(application).
-behaviour(supervisor).

-export([start/2, stop/1, init/1, traffic/0]).

start(_Type, _Args) ->
    supervisor:start_link({local, ranch_shop_sup}, ?MODULE, []).

stop(_State) ->
    ok.

init([]) ->
    Listener = ranch:child_spec(pos_listener, ranch_tcp,
                                #{socket_opts => [{port, 5555}], num_acceptors => 4,
                                  max_connections => 25},
                                pos_protocol, #{}),
    {ok, {#{strategy => one_for_one}, [Listener]}}.

%% The stores' tills, simulated (see tills.erl).
traffic() ->
    tills:start(5555).
