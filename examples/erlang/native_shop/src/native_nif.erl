%% The Erlang half of the native_shop NIFs: stubs the library replaces when
%% the module loads.
-module(native_nif).
-export([checksum/1, parse/1]).
-nifs([checksum/1, parse/1]).
-on_load(init/0).

init() ->
    Priv = case code:priv_dir(native_shop) of
               {error, bad_name} -> filename:join(filename:dirname(code:which(?MODULE)), "../priv");
               Dir -> Dir
           end,
    erlang:load_nif(filename:join(Priv, "native_nif"), 0).

checksum(_Bin) -> erlang:nif_error(not_loaded).
parse(_Bin) -> erlang:nif_error(not_loaded).
