-module(conn_sup).
-behaviour(supervisor).
-export([start_link/0, clients/0, init/1]).

start_link() -> supervisor:start_link({local, conn_sup}, ?MODULE, conns).

init(top) ->
    {ok, {#{strategy => one_for_one, intensity => 100, period => 60},
          [#{id => conn_sup, start => {conn_sup, start_link, []}, type => supervisor},
           #{id => clients, start => {conn_sup, clients, []}}]}};
init(conns) ->
    {ok, {#{strategy => simple_one_for_one},
          [#{id => conn, start => {conn, start_link, []}}]}}.

%% Clients reconnect when their connection is gone. Every 20 seconds two
%% of them send a bad line, a second apart.
clients() ->
    {ok, spawn_link(fun() -> clients(0) end)}.

clients(Tick) ->
    Conns = case catch supervisor:which_children(conn_sup) of
                L when is_list(L) -> [P || {_, P, _, _} <- L, is_pid(P)];
                _ -> []
            end,
    Missing = 50 - length(Conns),
    [catch supervisor:start_child(conn_sup, [C]) || C <- lists:seq(1, Missing)],
    [gen_server:cast(P, {line, <<"7">>}) || P <- Conns],
    case Tick rem 20 of
        10 -> bad(Conns);
        11 -> bad(Conns);
        _ -> ok
    end,
    timer:sleep(1000),
    clients(Tick + 1).

bad([P | _]) -> gen_server:cast(P, {line, <<"12,5">>});
bad([]) -> ok.
