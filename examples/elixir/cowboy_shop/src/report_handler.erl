-module(report_handler).
-behaviour(cowboy_handler).
-export([init/2]).

init(Req, State) ->
    {ok, Pdf} = report_server:render(cowboy_req:binding(id, Req)),
    {ok, cowboy_req:reply(200, #{<<"content-type">> => <<"application/pdf">>}, Pdf, Req), State}.
