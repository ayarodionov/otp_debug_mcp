defmodule OtpDebugMcp.Phoenix do
  @moduledoc """
  A Phoenix application on a node, sampled at the start and the end of a
  window, with its telemetry in between: its endpoints and how they're
  configured; its routers, and routes that an earlier route makes
  unreachable; its LiveView processes by view, with their memory, how it
  grows and, for the biggest, which assigns hold it; channels by module;
  PubSub topics by subscribers; and over the window, LiveView callbacks,
  channel messages and requests by route, with their times.

  Phoenix labels its processes (`$process_label`): a LiveView is
  `{Phoenix.LiveView, View, Topic}`, a channel `{Phoenix.Channel,
  Channel, Topic}`, a socket's transport `{Phoenix.Socket, Handler, Id}`.
  A LiveView keeps its assigns in its process for as long as the page is
  open: a list that grows with every PubSub message grows that process,
  in every open page. And a LiveView handles one message at a time, so a
  slow handle_event holds up everything else for that page.

  Reading a LiveView's assigns means asking for its state (sys:get_state,
  which the process answers between messages, half a second at most);
  that's done for the three biggest only. Nothing is changed.
  """

  alias OtpDebugMcp.{Checks, Format, Telemetry}

  # Processes and routes looked at, at most.
  @max_processes 20_000
  @max_routes 2_000

  @snapshot ~S"""
  Loaded = [M || {M, _} <- code:all_loaded()],
  Exports = fun(M, F, A) -> erlang:function_exported(M, F, A) end,
  Endpoints = [M || M <- Loaded, Exports(M, '__sockets__', 0), Exports(M, config, 2), is_pid(whereis(M))],
  Routers = [M || M <- Loaded, Exports(M, '__routes__', 0), Exports(M, '__match_route__', 3)],
  Listen = fun(Opts) when is_list(Opts) -> [KV || {K, _} = KV <- Opts, K =:= ip orelse K =:= port];
              (_) -> undefined
           end,
  Endpoint = fun(M) ->
    C = fun(K) -> case catch M:config(K) of {'EXIT', _} -> undefined; V -> V end end,
    %% Where it really listens (port 0 is a port the OS picked), where it can say.
    Bound = fun(Scheme) ->
      case catch M:server_info(Scheme) of
        {ok, {Ip, Port}} -> [{ip, Ip}, {port, Port}];
        _ -> Listen(C(Scheme))
      end
    end,
    {M, [{url, C(url)}, {http, Bound(http)}, {https, Bound(https)}, {adapter, C(adapter)},
         {server, C(server)}, {code_reloader, C(code_reloader)}, {debug_errors, C(debug_errors)},
         {check_origin, C(check_origin)}, {pubsub_server, C(pubsub_server)}],
     case catch M:'__sockets__'() of
       Ss when is_list(Ss) -> [{element(1, S), element(2, S)} || S <- Ss, is_tuple(S), tuple_size(S) >= 2];
       _ -> []
     end}
  end,
  Route = fun(R) ->
    Live = case maps:get(metadata, R, #{}) of
      #{phoenix_live_view := LV} when is_tuple(LV) -> element(1, LV);
      _ -> undefined
    end,
    {maps:get(verb, R, undefined), maps:get(path, R, undefined), maps:get(plug, R, undefined),
     maps:get(plug_opts, R, undefined), Live}
  end,
  Router = fun(M) ->
    case catch M:'__routes__'() of
      Rs when is_list(Rs) -> {M, length(Rs), [Route(R) || R <- lists:sublist(Rs, MaxRoutes), is_map(R)]};
      _ -> {M, 0, []}
    end
  end,
  %% Phoenix's own labels, without reading the whole dictionary when this
  %% OTP can say just the one key.
  Label = fun(P) ->
    case catch erlang:process_info(P, {dictionary, '$process_label'}) of
      {{dictionary, '$process_label'}, L} -> L;
      {'EXIT', _} ->
        case erlang:process_info(P, dictionary) of
          {dictionary, D} -> proplists:get_value('$process_label', D);
          _ -> undefined
        end;
      _ -> undefined
    end
  end,
  Info = fun(P) -> erlang:process_info(P, [memory, message_queue_len, current_function, reductions]) end,
  Procs = lists:foldl(
    fun(P, {LVs, Chans, Socks} = Acc) ->
      case Label(P) of
        {'Elixir.Phoenix.LiveView', View, Topic} ->
          case Info(P) of undefined -> Acc; I -> {[{P, View, Topic, I} | LVs], Chans, Socks} end;
        {'Elixir.Phoenix.Channel', Chan, Topic} ->
          case Info(P) of undefined -> Acc; I -> {LVs, [{P, Chan, Topic, I} | Chans], Socks} end;
        {'Elixir.Phoenix.Socket', Handler, _} ->
          {LVs, Chans, maps:update_with(Handler, fun(N) -> N + 1 end, 1, Socks)};
        _ -> Acc
      end
    end, {[], [], #{}}, lists:sublist(erlang:processes(), MaxProcs)),
  {LiveViews, Channels, Sockets} = Procs,
  %% Each endpoint's PubSub: subscriptions, and the topics with most.
  PubSubs = lists:usort([PS || {_, Conf, _} <- [Endpoint(E) || E <- Endpoints],
                               PS <- [proplists:get_value(pubsub_server, Conf)], is_atom(PS), PS =/= undefined]),
  PubSub = fun(Name) ->
    case catch 'Elixir.Registry':count(Name) of
      N when is_integer(N), N =< 200000 ->
        Keys = 'Elixir.Registry':select(Name, [{{'$1', '_', '_'}, [], ['$1']}]),
        Counts = lists:foldl(fun(K, A) -> maps:update_with(K, fun(C) -> C + 1 end, 1, A) end, #{}, Keys),
        {Name, N, lists:sublist(lists:reverse(lists:keysort(2, maps:to_list(Counts))), 10)};
      N when is_integer(N) -> {Name, N, []};
      _ -> {Name, undefined, []}
    end
  end,
  {ok, [Endpoint(E) || E <- Endpoints], [Router(R) || R <- Routers], LiveViews, Channels,
   maps:to_list(Sockets), [PubSub(PS) || PS <- PubSubs], erlang:monotonic_time(millisecond)}.
  """

  # The biggest assigns of a few LiveViews: each one's size (binaries
  # included), and a list's length.
  @assigns ~S"""
  [{P, case catch sys:get_state(P, 500) of
         #{socket := #{assigns := A}} when is_map(A) ->
           lists:sublist(lists:reverse(lists:keysort(2,
             [{K, erlang:external_size(V), case is_list(V) of true -> length(V); false -> undefined end}
              || {K, V} <- maps:to_list(A), K =/= '__changed__', K =/= flash])), 5);
         _ -> busy
       end} || P <- Pids].
  """

  @events [
    "phoenix.live_view.mount.stop",
    "phoenix.live_view.handle_params.stop",
    "phoenix.live_view.handle_event.stop",
    "phoenix.live_view.handle_event.exception",
    "phoenix.live_component.handle_event.stop",
    "phoenix.channel_handled_in",
    "phoenix.router_dispatch.stop"
  ]

  @doc "The Phoenix application on the node, sampled `duration_ms` apart."
  def report(duration_ms) do
    with {:ok, first} <- snapshot() do
      case first do
        {:ok, [], _, _, _, _, _, _} ->
          {:error, "no Phoenix endpoint is running on this node"}

        _ ->
          # The biggest LiveView of each of the three biggest views, whose
          # assigns are read at both ends of the window: a process's memory
          # grows in steps, as its heap does, but a growing assign shows.
          watched = watched(first)
          sizes0 = assigns(watched)
          telemetry = Telemetry.listen(@events, duration_ms)
          if match?({:error, _}, telemetry), do: Process.sleep(duration_ms)

          with {:ok, last} <- snapshot() do
            {:ok, analyze(first, last, telemetry, {watched, sizes0, assigns(watched)})}
          end
      end
    end
  end

  defp snapshot,
    do: Checks.remote_eval(@snapshot, MaxRoutes: @max_routes, MaxProcs: @max_processes)

  defp watched({:ok, _, _, lvs, _, _, _, _}) do
    lvs
    |> Enum.group_by(fn {_, view, _, _} -> view end, fn {pid, _, _, i} -> {pid, i[:memory]} end)
    |> Enum.map(fn {_, procs} -> Enum.max_by(procs, &elem(&1, 1)) end)
    |> Enum.sort_by(&(-elem(&1, 1)))
    |> Enum.take(3)
    |> Enum.map(&elem(&1, 0))
  end

  defp assigns([]), do: %{}

  defp assigns(pids) do
    case Checks.remote_eval(@assigns, Pids: pids) do
      {:ok, rows} -> Map.new(rows)
      _ -> %{}
    end
  end

  # -- Analysis ------------------------------------------------------------------

  defp analyze(first, last, telemetry, sizes) do
    {:ok, _, _, lvs0, chans0, _, _, t0} = first
    {:ok, endpoints, routers, lvs, chans, sockets, pubsubs, t1} = last
    elapsed = max(t1 - t0, 1)

    views = views(lvs0, lvs, elapsed, sizes)
    window = window(telemetry, elapsed)

    report =
      %{
        endpoints: Enum.map(endpoints, &endpoint/1),
        routers: Enum.map(routers, &router/1),
        window_ms: elapsed
      }
      |> put(:live_views, views != [] && views)
      |> put(:channels, channels(chans0, chans))
      |> put(:sockets, sockets != [] && Map.new(sockets, fn {h, n} -> {module(h), n} end))
      |> put(:pubsub, pubsub(pubsubs))
      |> Map.merge(window)

    notes = findings(report) |> Enum.sort_by(fn {level, _} -> level_rank(level) end)

    report
    |> Map.put(:status, status(notes))
    |> Map.put(:findings, for({level, text} <- notes, do: "#{level}: #{text}"))
    |> Map.put(:interpretation, interpretation())
  end

  defp endpoint({mod, conf, sockets}) do
    conf = Map.new(conf)

    %{
      endpoint: module(mod),
      sockets: Enum.map(sockets, fn {path, m} -> "#{path} -> #{module(m)}" end)
    }
    |> put(:url, url(conf[:url]))
    |> put(:http, listen(conf[:http]))
    |> put(:https, listen(conf[:https]))
    |> put(:adapter, conf[:adapter] && conf[:adapter] != :undefined && module(conf[:adapter]))
    |> Map.put(:server, conf[:server] == true)
    |> put(:code_reloader, conf[:code_reloader] == true)
    |> put(:debug_errors, conf[:debug_errors] == true)
    |> put(:check_origin, conf[:check_origin] == false && false_origin())
    |> put(
      :pubsub_server,
      conf[:pubsub_server] not in [nil, :undefined] && module(conf[:pubsub_server])
    )
  end

  # check_origin: false is put as the text, so it isn't dropped.
  defp false_origin, do: "false: any site's pages may open its sockets"

  defp url(url) when is_list(url) do
    host = url[:host] || "localhost"

    "#{url[:scheme] || "http"}://#{host}#{if url[:port], do: ":#{url[:port]}", else: ""}#{url[:path] || ""}"
  end

  defp url(_), do: false

  defp listen(opts) when is_list(opts) and opts != [] do
    ip = opts[:ip]
    "#{if is_tuple(ip), do: :inet.ntoa(ip), else: "*"}:#{opts[:port]}"
  end

  defp listen(_), do: false

  defp router({mod, count, routes}) do
    shadowed = shadowed(routes)

    %{router: module(mod), routes: count}
    |> put(:live_routes, Enum.count(routes, &(elem(&1, 4) not in [nil, :undefined])))
    |> put(:shadowed, shadowed != [] && shadowed)
  end

  # A route is unreachable when an earlier one, for the same verb (or any),
  # matches every path it does: Phoenix takes the first that matches.
  defp shadowed(routes) do
    routes
    |> Enum.with_index()
    |> Enum.flat_map(fn {{verb, path, _, _, _} = route, i} ->
      earlier = Enum.take(routes, i)

      case Enum.find(earlier, fn {v, p, _, _, _} ->
             v in [verb, :*] and covers?(segments(p), segments(path))
           end) do
        nil -> []
        by -> [%{route: describe(route), unreachable_because_of: describe(by)}]
      end
    end)
    |> Enum.take(10)
  end

  defp segments(path) when is_binary(path), do: String.split(path, "/", trim: true)
  defp segments(_), do: []

  defp covers?([], []), do: true
  defp covers?(["*" <> _ | _], _), do: true
  defp covers?([":" <> _ | a], [_ | b]), do: covers?(a, b)
  defp covers?([s | a], [s | b]), do: covers?(a, b)
  defp covers?(_, _), do: false

  defp describe({verb, path, plug, opts, live}) do
    target =
      if live not in [nil, :undefined],
        do: "live #{module(live)}",
        else: "#{module(plug)} #{inspect(opts)}"

    "#{verb |> to_string() |> String.upcase()} #{path} -> #{target}"
  end

  # LiveView processes by view: how many, their memory and its growth over
  # the window, their mailboxes, and where they are.
  defp views(lvs0, lvs, elapsed, {watched, sizes0, sizes1}) do
    before = Map.new(lvs0, fn {pid, _, _, i} -> {pid, i} end)

    groups =
      lvs
      |> Enum.group_by(fn {_, view, _, _} -> view end)
      |> Enum.map(fn {view, procs} ->
        mems = Enum.map(procs, fn {_, _, _, i} -> i[:memory] end)

        growth =
          for {pid, _, _, i} <- procs, i0 = before[pid], is_list(i0) do
            (i[:memory] - i0[:memory]) * 1000 / elapsed
          end

        busy = Enum.reject(procs, fn {_, _, _, i} -> waiting?(i[:current_function]) end)

        %{
          view: module(view),
          processes: length(procs),
          memory_bytes: %{
            total: Enum.sum(mems),
            max: Enum.max(mems),
            mean: div(Enum.sum(mems), length(mems))
          },
          mailbox_max:
            procs |> Enum.map(fn {_, _, _, i} -> i[:message_queue_len] end) |> Enum.max()
        }
        |> put(:memory_growth, growth(growth))
        |> put(:busy_now, busy != [] && doing(busy))
        |> Map.put(:biggest, biggest_pid(procs, watched))
      end)
      |> Enum.sort_by(&(-&1.memory_bytes.total))
      |> Enum.take(10)

    for g <- groups do
      {pid, g} = Map.pop(g, :biggest)

      g
      |> Map.put(:biggest_process, Format.inspect(pid))
      |> put(:biggest_assigns, biggest_assigns(sizes1[pid], sizes0[pid], elapsed))
    end
  end

  # The view's watched process, if it's still there, or its biggest.
  defp biggest_pid(procs, watched) do
    case Enum.find(procs, fn {pid, _, _, _} -> pid in watched end) do
      {pid, _, _, _} -> pid
      nil -> procs |> Enum.max_by(fn {_, _, _, i} -> i[:memory] end) |> elem(0)
    end
  end

  defp growth([]), do: false

  defp growth(rates) do
    growing = Enum.count(rates, &(&1 > 1_000))

    %{
      processes_compared: length(rates),
      growing: growing,
      mean_bytes_per_s: round(Enum.sum(rates) / length(rates))
    }
  end

  defp biggest_assigns(nil, _, _), do: false
  defp biggest_assigns(:busy, _, _), do: "busy: it didn't answer within 500 ms"

  defp biggest_assigns(rows, before, elapsed) do
    before = if is_list(before), do: Map.new(before, fn {k, b, l} -> {k, {b, l}} end), else: %{}

    for {key, bytes, len} <- rows, bytes > 100 do
      grew =
        case before[key] do
          {b0, l0} when bytes > b0 ->
            %{bytes_per_s: round((bytes - b0) * 1000 / elapsed)}
            |> put(:length, (is_integer(len) and is_integer(l0) and len > l0) && len - l0)

          _ ->
            false
        end

      %{assign: Atom.to_string(key), bytes: bytes}
      |> put(:length, is_integer(len) && len)
      |> put(:grew_in_window, grew)
    end
  end

  # Waiting for its next message, in gen_server's loop.
  defp waiting?({:gen_server, :loop, _}), do: true
  defp waiting?({:erlang, :hibernate, _}), do: true
  defp waiting?(_), do: false

  defp doing(procs) do
    procs
    |> Enum.map(fn {_, _, _, i} -> mfa(i[:current_function]) end)
    |> Enum.frequencies()
    |> Enum.sort_by(fn {_, n} -> -n end)
    |> Enum.take(3)
    |> Enum.map(fn {fun, n} -> %{processes: n, in: fun} end)
  end

  defp channels(_, []), do: false

  defp channels(chans0, chans) do
    before = Map.new(chans0, fn {pid, _, _, i} -> {pid, i} end)

    chans
    |> Enum.group_by(fn {_, chan, _, _} -> chan end)
    |> Enum.map(fn {chan, procs} ->
      growth =
        for {pid, _, _, i} <- procs, i0 = before[pid], is_list(i0), do: i[:memory] - i0[:memory]

      %{
        channel: module(chan),
        processes: length(procs),
        topics: procs |> Enum.map(&elem(&1, 2)) |> Enum.uniq() |> length(),
        memory_bytes_max: procs |> Enum.map(fn {_, _, _, i} -> i[:memory] end) |> Enum.max(),
        mailbox_max: procs |> Enum.map(fn {_, _, _, i} -> i[:message_queue_len] end) |> Enum.max()
      }
      |> put(:growing, Enum.count(growth, &(&1 > 10_000)))
    end)
    |> Enum.sort_by(&(-&1.processes))
  end

  defp pubsub([]), do: false

  defp pubsub(list) do
    for {name, n, top} <- list do
      %{pubsub: module(name), subscriptions: n}
      |> put(
        :topics_with_most,
        top != [] && for({t, c} <- top, do: %{topic: topic(t), subscribers: c})
      )
    end
  end

  defp topic(t) when is_binary(t), do: t
  defp topic(t), do: Format.inspect(t)

  # -- The window's telemetry ------------------------------------------------------

  defp window({:error, reason}, _), do: %{not_listened: Format.inspect(reason)}

  defp window({:ok, report}, elapsed) do
    events = Map.new(report.by_event, &{&1.event, &1})
    get = fn name -> Map.get(events, name, %{groups: [], count: 0}) end

    live =
      ["mount", "handle_params", "handle_event"]
      |> Enum.flat_map(fn cb ->
        Enum.map(get.("phoenix.live_view.#{cb}.stop").groups, &{cb, &1})
      end)
      |> Kernel.++(
        Enum.map(
          get.("phoenix.live_component.handle_event.stop").groups,
          &{"component event", &1}
        )
      )
      |> slowest()

    %{listened_ms: elapsed}
    |> put(:live_view_callbacks, live)
    |> put(
      :channel_messages,
      slowest(Enum.map(get.("phoenix.channel_handled_in").groups, &{"handle_in", &1}))
    )
    |> put(
      :requests,
      slowest(Enum.map(get.("phoenix.router_dispatch.stop").groups, &{"request", &1}))
    )
    |> put(
      :exceptions,
      report.exceptions != [] &&
        Enum.map(report.exceptions, &Map.take(&1, [:count, :key, :kind, :reason]))
    )
    |> then(&%{window: &1})
  end

  defp slowest(groups) do
    top =
      groups
      |> Enum.filter(fn {_, g} -> g[:duration_ms] end)
      |> Enum.sort_by(fn {_, g} -> -g.duration_ms.p95 end)
      |> Enum.take(8)

    top != [] &&
      for {kind, g} <- top do
        %{
          what: if(kind in ["request", "handle_in"], do: g.key, else: "#{g.key} (#{kind})"),
          count: g.count,
          p50_ms: g.duration_ms.p50,
          p95_ms: g.duration_ms.p95,
          max_ms: g.duration_ms.max
        }
      end
  end

  # -- Findings ------------------------------------------------------------------

  defp findings(r) do
    routes =
      for %{router: router, shadowed: [_ | _] = s} <- r.routers do
        {:warning,
         "#{router}: #{length(s)} routes can't be reached, an earlier route matching all their paths: #{hd(s).route} (because of #{hd(s).unreachable_because_of})#{if length(s) > 1, do: " and more", else: ""}. Phoenix takes the first route that matches; move the specific one up"}
      end

    endpoints =
      for e <- r.endpoints, e[:code_reloader] do
        {:info,
         "#{e.endpoint} has code_reloader on: every request first checks for changed source files, which is for development"}
      end

    views =
      Enum.flat_map(r[:live_views] || [], fn v ->
        grew = growing_assign(v[:biggest_assigns])

        grow =
          case {v[:memory_growth], grew} do
            {_, %{assign: a, bytes: b, grew_in_window: g} = top} ->
              [
                {if(v.memory_bytes.total > 100_000_000, do: :critical, else: :warning),
                 "#{v.view}'s assign #{a} grew through the window in its biggest process, #{div(g.bytes_per_s, 1000)} KB a second#{if g[:length], do: ", #{g.length} more items", else: ""}, to #{div(b, 1000)} KB#{if top[:length], do: " (a list of #{top.length})", else: ""}; the #{v.processes} #{v.view} processes hold #{div(v.memory_bytes.total, 1_000_000)} MB in all: a LiveView keeps its assigns for as long as the page is open, so whatever is added to them, per message or event, stays, in every open page. Keep what grows bounded, or put it in a stream (stream/3), which the process doesn't keep"}
              ]

            {%{growing: g, processes_compared: n, mean_bytes_per_s: rate}, _}
            when g > 0 and g * 2 >= n and rate > 2_000 ->
              big = biggest(v[:biggest_assigns])

              [
                {if(v.memory_bytes.total > 100_000_000, do: :critical, else: :warning),
                 "#{g} of #{n} #{v.view} processes grew through the window, #{div(rate, 1000)} KB a second each on average, #{div(v.memory_bytes.total, 1_000_000)} MB in all (the biggest #{div(v.memory_bytes.max, 1_000_000)} MB)#{big}: a LiveView keeps its assigns for as long as the page is open, so whatever is added to them, per message or event, stays. Keep what grows bounded, or put it in a stream (stream/3), which the process doesn't keep"}
              ]

            _ ->
              []
          end

        mailbox =
          if v.mailbox_max > 100 do
            [
              {:warning,
               "a #{v.view} process has #{v.mailbox_max} messages waiting: it handles one at a time, and can't keep up#{case v[:busy_now] do
                 [b | _] -> "; #{b.processes} were busy in #{b.in} when looked at"
                 _ -> ""
               end}"}
            ]
          else
            []
          end

        grow ++ mailbox
      end)

    slow =
      for c <- get_in(r, [:window, :live_view_callbacks]) || [], c.p95_ms >= 200 do
        {:warning,
         "#{c.what} takes #{c.p95_ms} ms at p95 (#{c.count} in the window): the LiveView process does nothing else meanwhile, so that page's other events and its PubSub messages wait. Move the slow work out of the callback: start_async/3 or assign_async/3"}
      end
      |> Enum.take(3)

    channels =
      for c <- r[:channels] || [], c.mailbox_max > 100 do
        {:warning,
         "a #{c.channel} process has #{c.mailbox_max} messages waiting: it can't keep up"}
      end

    raised =
      case get_in(r, [:window, :exceptions]) do
        [_ | _] = ex ->
          [
            {:warning,
             "#{ex |> Enum.map(& &1.count) |> Enum.sum()} LiveView callbacks or requests raised in the window: see window.exceptions"}
          ]

        _ ->
          []
      end

    routes ++ views ++ slow ++ channels ++ raised ++ endpoints
  end

  # The assign that grew most through the window, by more than 1 KB a second.
  defp growing_assign(rows) when is_list(rows) do
    rows
    |> Enum.filter(&(&1[:grew_in_window] && &1.grew_in_window.bytes_per_s > 1_000))
    |> Enum.max_by(& &1.grew_in_window.bytes_per_s, fn -> nil end)
  end

  defp growing_assign(_), do: nil

  defp biggest([%{assign: a, bytes: b} = top | _]) when b > 100_000 do
    "; in the biggest, the assign #{a} holds #{div(b, 1000)} KB#{if top[:length], do: ", a list of #{top.length}", else: ""}"
  end

  defp biggest(_), do: ""

  defp level_rank(:critical), do: 0
  defp level_rank(:warning), do: 1
  defp level_rank(_), do: 2

  defp status(notes) do
    cond do
      Enum.any?(notes, &(elem(&1, 0) == :critical)) -> :critical
      Enum.any?(notes, &(elem(&1, 0) == :warning)) -> :warning
      true -> :ok
    end
  end

  # Each module in its own language's syntax.
  defp mfa({m, f, a}) when is_atom(m),
    do: "#{module(m)}#{if elixir?(m), do: ".", else: ":"}#{f}/#{a}"

  defp mfa(other), do: Format.inspect(other)

  defp module(m) when is_atom(m),
    do: if(elixir?(m), do: Format.inspect(m), else: Atom.to_string(m))

  defp module(m), do: Format.inspect(m)
  defp elixir?(m), do: is_atom(m) and String.starts_with?(Atom.to_string(m), "Elixir.")

  defp put(map, _key, value) when value in [nil, false], do: map
  defp put(map, key, value), do: Map.put(map, key, value)

  defp interpretation do
    """
    endpoints: each running Phoenix endpoint, where it listens, its
    sockets, and settings worth knowing (code_reloader, debug_errors,
    check_origin false). routers: routes, and shadowed ones, which an
    earlier route for the same verb matches first, so they never run.
    live_views: LiveView processes by view, one per open page: memory
    (total, max, mean), memory_growth over the window (processes growing,
    mean bytes a second), the longest mailbox, the busy ones and where,
    and for the biggest process of the three biggest views,
    biggest_assigns: each assign's size, a list's length, and how much it
    grew between the start and the end of the window (memory grows in
    steps, as the heap does; a growing assign shows at once). channels: channel processes
    by module. pubsub: subscriptions, and topics with most subscribers
    (each gets every broadcast). window: LiveView callbacks (mount,
    handle_params, handle_event), channel messages and requests, slowest
    first, from Phoenix's telemetry. Next step: process_info on a
    biggest_process; module_code on the view's handle_info and
    handle_event.
    """
  end
end
