%% Erlang book, chapter 1, section 4.5: permanent per-connection workers.
%% 50 connections under a simple_one_for_one supervisor with the defaults;
%% now and then a client sends a line that isn't a number.
-module(conn).
-behaviour(gen_server).
-export([start/0, start_link/1, init/1, handle_call/3, handle_cast/2]).

start() ->
    spawn(fun() ->
        {ok, _} = supervisor:start_link({local, gateway_sup}, conn_sup, top),
        receive never -> ok end
    end),
    ok.

start_link(Client) -> gen_server:start_link(?MODULE, Client, []).

init(Client) -> {ok, #{client => Client, total => 0}}.

handle_cast({line, Line}, S = #{total := T}) ->
    {noreply, S#{total := T + binary_to_integer(Line)}}.

handle_call(_, _, S) -> {reply, ok, S}.
