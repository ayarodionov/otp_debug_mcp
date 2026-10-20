defmodule OtpDebugMcp.ProcessContext do
  @moduledoc """
  What process_info adds about a process's life: an estimate of its age,
  and, if a supervisor started it, that supervisor's restart history.

  BEAM doesn't record when a process started. But pids are numbered in
  spawn order: within a serial, the number only grows (checked on OTP 26
  and 28), so the gap between a process's pid and a fresh one counts the
  processes spawned since. Some of those are ours (every rpc spawns one;
  `OtpDebugMcp.Target` logs when), and the rest come at the node's own
  spawn rate, measured over half a second. The age is the time back at
  which the two add up to the count. It reliably tells a process restarted
  a moment ago from one that has run for days; for old processes it's
  rough, since it assumes the current rate held all along.
  """

  alias OtpDebugMcp.{Checks, Format, Target}

  @window_ms 500

  # Pids print as <0.Number.Serial> on their own node. The parent comes
  # from process_info(parent) (OTP 25+), or else the first $ancestor.
  @code ~S"""
  Num = fun(P) ->
    [_, N, S] = string:lexemes(erlang:pid_to_list(P), "<.>"),
    {list_to_integer(S), list_to_integer(N)}
  end,
  Fresh = fun() -> Num(spawn(fun() -> ok end)) end,
  This = Num(Pid),
  First = Fresh(),
  Parent =
    case catch erlang:process_info(Pid, parent) of
      {parent, Pa} when is_pid(Pa) -> Pa;
      _ ->
        case erlang:process_info(Pid, dictionary) of
          {dictionary, Dict} ->
            case proplists:get_value('$ancestors', Dict) of
              [A | _] when is_pid(A) -> A;
              [A | _] when is_atom(A) -> whereis(A);
              _ -> undefined
            end;
          _ -> undefined
        end
    end,
  Sup =
    case is_pid(Parent) andalso InitialCall(Parent) of
      {supervisor, _, _} ->
        SupName =
          case erlang:process_info(Parent, registered_name) of
            {registered_name, RN} when is_atom(RN) -> RN;
            _ -> Parent
          end,
        case catch sys:get_state(Parent, 1000) of
          {'EXIT', _} ->
            {SupName, unresponsive, []};
          SupState ->
            Hist = History(SupState),
            Ids =
              case Hist of
                {static, _, _, _, _} ->
                  [Id || {Id, Child, _, _} <- supervisor:which_children(Parent), Child =:= Pid];
                _ ->
                  []
              end,
            {SupName, Hist, Ids}
        end;
      _ ->
        undefined
    end,
  timer:sleep(Window),
  Second = Fresh(),
  {UptimeMs, _} = erlang:statistics(wall_clock),
  {This, First, Second, UptimeMs, erlang:monotonic_time(second), Sup, is_process_alive(Pid)}.
  """

  @doc "Age estimate and supervisor context for `pid` on the target. Takes about #{@window_ms}ms."
  def describe(pid) do
    started = System.monotonic_time(:microsecond)
    code = Checks.supervisor_funs() <> @code

    with {:ok, {this, first, second, uptime_ms, now, sup, alive?}} <-
           Checks.remote_eval(code, Pid: pid, Window: @window_ms) do
      # Including the spawn for this very call, a moment after `started`.
      own = Target.own_spawn_ages(started, 100_000)

      {:ok,
       %{age: age(this, first, second, uptime_ms, own), supervisor: supervisor(sup, now)}
       |> Map.merge(if alive?, do: %{}, else: %{exited_during_check: true})}
    end
  end

  defp age({serial, n}, {serial, n1}, {serial, n2}, uptime_ms, own) do
    uptime_s = uptime_ms / 1000
    # Processes strictly between two pids: the probes themselves don't count.
    since = max(n1 - n - 1, 0)
    rate = max(n2 - n1 - 1, 0) / (@window_ms / 1000)
    average = if serial == 0 and uptime_s > 0, do: n1 / uptime_s, else: 0
    estimate = min(solve(since, rate, average, own, 0, 0.0), uptime_s)
    ours = Enum.count(own, &(&1 <= estimate))
    # A hard bound: had the process been older than our (since + 1)th most
    # recent spawn, at least since + 1 processes would have come after it.
    younger_than = Enum.at(own, since)

    %{
      estimated_seconds: round_age(estimate),
      younger_than_seconds: younger_than && round_age(max(younger_than, estimate)),
      spawned_since: since,
      spawned_since_by_this_tool: ours,
      node_spawn_rate_per_second: Float.round(rate * 1.0, 1),
      node_uptime_seconds: round(uptime_s),
      how:
        "An estimate: BEAM doesn't record when a process started. Pids are numbered " <>
          "in spawn order: #{since} processes were spawned after this one, #{ours} of " <>
          "them by this tool's own calls and the rest at the node's spawn rate. " <>
          "Reliable for telling a fresh process from an old one; rough for old ones. " <>
          "younger_than_seconds is certain: it's when this tool spawned more " <>
          "processes on the node than have been spawned since this one."
    }
  end

  defp age(_this, _first, _second, uptime_ms, _own) do
    %{
      estimated_seconds: nil,
      node_uptime_seconds: round(uptime_ms / 1000),
      how:
        "Old: the pid counter has wrapped around since this process was spawned " <>
          "(hundreds of millions of spawns ago)."
    }
  end

  # The age t at which the node's own spawns (rate * t) plus ours (those
  # in the last t seconds) add up to `since`. Walking back through our
  # spawns (ages ascending), the total grows at `rate` between them and
  # steps up by one at each.
  #
  # With no spawns of the node's own, the process came between two of
  # ours, and the midpoint is the best guess. Past our oldest logged
  # spawn, the average rate since boot is all there is to go on.
  defp solve(since, rate, _average, rest, k, prev) when k >= since do
    case rest do
      [next | _] when rate == 0 -> (prev + next) / 2
      _ -> prev
    end
  end

  defp solve(since, rate, average, [age | rest], k, prev) do
    if rate > 0 and (since - k) / rate < age,
      do: max((since - k) / rate, prev),
      else: solve(since, rate, average, rest, k + 1, age)
  end

  defp solve(since, rate, average, [], k, prev) do
    rate = if rate > 0, do: rate, else: average
    if rate > 0, do: prev + (since - k) / rate, else: prev
  end

  defp round_age(s) when s < 10, do: Float.round(s * 1.0, 1)
  defp round_age(s), do: round(s)

  defp supervisor(:undefined, _now), do: nil

  defp supervisor({name, :unresponsive, _ids}, _now),
    do: %{supervisor: Format.inspect(name), unresponsive: true}

  defp supervisor({name, {kind, strategy, intensity, period, restarts}, ids}, now) do
    %{
      supervisor: Format.inspect(name),
      kind: kind,
      strategy: strategy,
      child_id: child_id(ids)
    }
    |> Map.merge(Checks.restart_summary(now, intensity, period, restarts))
  end

  defp supervisor({name, :unknown, _ids}, _now), do: %{supervisor: Format.inspect(name)}

  defp child_id([id]), do: Format.inspect(id)
  defp child_id(_), do: nil
end
