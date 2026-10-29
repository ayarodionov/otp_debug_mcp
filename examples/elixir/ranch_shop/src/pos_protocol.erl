%% The tills' protocol, one line at a time:
%%
%%     PRICE <sku>          -> PRICE <sku> <cents>
%%     SALE <sku> <qty>     -> OK <total cents>
%%     BYE                  -> (closes)
-module(pos_protocol).
-behaviour(ranch_protocol).

-export([start_link/3, init/2]).

start_link(Ref, Transport, _Opts) ->
    {ok, proc_lib:spawn_link(?MODULE, init, [Ref, Transport])}.

init(Ref, Transport) ->
    {ok, Socket} = ranch:handshake(Ref),
    ok = Transport:setopts(Socket, [{packet, line}]),
    loop(Socket, Transport).

loop(Socket, Transport) ->
    case Transport:recv(Socket, 0, infinity) of
        {ok, Line} ->
            case handle(string:trim(Line)) of
                close ->
                    Transport:close(Socket);
                Reply ->
                    ok = Transport:send(Socket, [Reply, $\n]),
                    loop(Socket, Transport)
            end;
        {error, _} ->
            ok = Transport:close(Socket)
    end.

handle(<<"PRICE ", Sku/binary>>) ->
    [<<"PRICE ">>, Sku, $\s, integer_to_binary(price(Sku))];
handle(<<"SALE ", Rest/binary>>) ->
    [Sku, Qty] = binary:split(Rest, <<" ">>),
    [<<"OK ">>, integer_to_binary(price(Sku) * binary_to_integer(Qty))];
handle(<<"BYE">>) ->
    close.

price(Sku) ->
    100 + erlang:phash2(Sku, 9900).
