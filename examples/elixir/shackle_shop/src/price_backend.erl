%% The pricing backend: answers each connection's requests in order, as
%% such services do. A price takes a millisecond, an export 800.
-module(price_backend).
-export([start/1]).

start(Port) ->
    Parent = self(),
    spawn(fun() ->
                  {ok, L} = gen_tcp:listen(Port, [binary, {packet, line}, {active, false}, {reuseaddr, true}]),
                  Parent ! listening,
                  accept(L)
          end),
    receive listening -> ok end.

accept(L) ->
    {ok, S} = gen_tcp:accept(L),
    Pid = spawn(fun() -> receive go -> serve(S) end end),
    ok = gen_tcp:controlling_process(S, Pid),
    Pid ! go,
    accept(L).

serve(S) ->
    case gen_tcp:recv(S, 0) of
        {ok, Line} ->
            [Id | Request] = binary:split(string:trim(Line), <<" ">>, [global]),
            ok = gen_tcp:send(S, [Id, <<" ">>, answer(Request), <<"\n">>]),
            serve(S);
        _ ->
            ok
    end.

answer([<<"get">>, Sku]) ->
    timer:sleep(1),
    integer_to_binary(binary_to_integer(Sku) * 7 rem 100 + 1);
answer([<<"export">>]) ->
    timer:sleep(800),
    <<"exported">>.
