%% The shop's API, a Yaws appmod.
-module(shop_api).
-export([out/1]).

out(Arg) ->
    case yaws_api:arg_appmoddata(Arg) of
        "products" ->
            {content, "application/json", <<"[{\"id\":1,\"name\":\"kettle\"}]">>};
        "cart" ->
            Cookie = yaws_api:new_cookie_session(#{cart => [], recommendations => recommendations()}),
            [{content, "application/json", <<"{\"cart\":[]}">>},
             yaws_api:set_cookie("shop_session", Cookie, [{path, "/"}])];
        _ ->
            {status, 404}
    end.

recommendations() ->
    [#{id => N, name => <<"product ", (integer_to_binary(N))/binary>>, score => rand:uniform()}
     || N <- lists:seq(1, 20)].
