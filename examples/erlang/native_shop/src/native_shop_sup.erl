-module(native_shop_sup).
-behaviour(supervisor).
-export([start_link/0, init/1]).

start_link() -> supervisor:start_link({local, ?MODULE}, ?MODULE, []).

init([]) ->
    Order = crypto:strong_rand_bytes(4096),
    Record = crypto:strong_rand_bytes(1024),
    Worker = fun(Name, Interval, Fun) ->
                 #{id => Name, start => {native_shop_worker, start_link, [Name, Interval, Fun]}}
             end,
    {ok, {#{strategy => one_for_one},
          [Worker(native_pricing, 300, fun() -> native_nif:checksum(Order) end),
           Worker(native_ingest, 100, fun() -> native_nif:parse(Record) end)]}}.
