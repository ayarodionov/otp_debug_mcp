%% The stores' tills, simulated, all on 127.0.0.1:
%%
%% - 40 tills in the main stores, each keeping one connection and asking
%%   for a price twice a second;
%% - 12 tills in the outlet stores, behind a NAT that drops idle
%%   connections without telling either end: every 5 seconds each finds
%%   its connection dead and opens a new one, and the old one, as far as
%%   the server can tell, is still there;
%% - a new till coming online every 3 seconds, which asks for one price
%%   and closes.
-module(tills).

-export([start/1]).

start(Port) ->
    [spawn(fun() -> main(Port) end) || _ <- lists:seq(1, 40)],
    [spawn(fun() -> outlet(Port, []) end) || _ <- lists:seq(1, 12)],
    spawn(fun() -> newcomers(Port) end),
    ok.

connect(Port) ->
    gen_tcp:connect({127, 0, 0, 1}, Port, [binary, {active, false}, {packet, line}], 2000).

ask(Socket, Line) ->
    ok = gen_tcp:send(Socket, [Line, $\n]),
    {ok, _} = gen_tcp:recv(Socket, 0, 10000).

main(Port) ->
    case connect(Port) of
        {ok, Socket} ->
            catch prices(Socket),
            gen_tcp:close(Socket);
        _ ->
            ok
    end,
    timer:sleep(1000),
    main(Port).

prices(Socket) ->
    ask(Socket, ["PRICE ", integer_to_list(rand:uniform(5000))]),
    timer:sleep(500),
    prices(Socket).

%% The NAT dropped the last connection: this end gives up on it (and,
%% being dropped, sends nothing on it, not even a close).
outlet(Port, Dead) ->
    New = case connect(Port) of
        {ok, Socket} ->
            catch ask(Socket, "PRICE 42"),
            [Socket];
        _ ->
            []
    end,
    timer:sleep(5000),
    outlet(Port, New ++ Dead).

newcomers(Port) ->
    spawn(fun() ->
        case connect(Port) of
            {ok, Socket} ->
                catch ask(Socket, "PRICE 7"),
                gen_tcp:send(Socket, "BYE\n"),
                gen_tcp:close(Socket);
            _ ->
                ok
        end
    end),
    timer:sleep(3000),
    newcomers(Port).
