-module(products_handler).
-behaviour(cowboy_handler).
-export([init/2]).

init(Req, State) ->
    Body = <<"[{\"id\":1,\"name\":\"kettle\"},{\"id\":2,\"name\":\"teapot\"}]">>,
    {ok, cowboy_req:reply(200, #{<<"content-type">> => <<"application/json">>}, Body, Req), State}.
