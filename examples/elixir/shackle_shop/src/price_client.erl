%% The pricing backend's protocol, for shackle: a line per request,
%% "Id get Sku" or "Id export", answered "Id Result".
-module(price_client).
-behaviour(shackle_client).
-export([init/1, setup/2, handle_request/2, handle_data/2, terminate/1]).

init(_) -> {ok, #{next => 0, buffer => <<>>}}.

setup(_Socket, State) -> {ok, State}.

handle_request({get, Sku}, #{next := Id} = State) ->
    {ok, Id, [integer_to_binary(Id), <<" get ">>, integer_to_binary(Sku), <<"\n">>], State#{next := Id + 1}};
handle_request(export, #{next := Id} = State) ->
    {ok, Id, [integer_to_binary(Id), <<" export\n">>], State#{next := Id + 1}}.

handle_data(Data, #{buffer := Buffer} = State) ->
    Lines = binary:split(<<Buffer/binary, Data/binary>>, <<"\n">>, [global]),
    {Complete, [Rest]} = lists:split(length(Lines) - 1, Lines),
    Replies = [begin
                   [Id, Result] = binary:split(Line, <<" ">>),
                   {binary_to_integer(Id), Result}
               end || Line <- Complete, Line =/= <<>>],
    {ok, Replies, State#{buffer := Rest}}.

terminate(_State) -> ok.
