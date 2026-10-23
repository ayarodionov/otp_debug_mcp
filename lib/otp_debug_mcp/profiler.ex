defmodule OtpDebugMcp.Profiler do
  @moduledoc """
  Where the time goes on the target, by function: the runtime's call_time
  and call_memory counters, the ones `eprof` and `tprof` use, over a short
  window.

  The counters only count calls of functions that have a pattern, made by
  processes with the `call` trace flag, and send no trace messages, so
  there's no flood to guard against; the cost is extra work on every
  counted call. They measure a function's own time: time spent in another
  profiled function counts toward that one, time in a function that isn't
  profiled toward its caller. Only time a process spends running counts,
  not time it spends waiting. Memory is counted the same way.

  As in `OtpDebugMcp.Tracer`, a holder process spawned on the target with
  erl_eval does the work, so no code of ours has to exist there. It sets
  the counters up, waits for the window, pauses them, reads and ranks them,
  and sends back only the top of each ranking.

    * **OTP 27+: an isolated trace session.** The counters belong to the
      holder's session, so other tracing on the node, in any session, is
      neither seen nor disturbed, and the session goes when the holder
      does.

    * **Older nodes: the legacy trace session**, which is shared by
      everything that traces on the node, `dbg` and `recon_trace` included.
      Setting the counters up and clearing them afterwards would end such
      tracing, so the profile is refused while there is any, unless forced.
  """

  alias OtpDebugMcp.{Checks, Format, Target, Tracer}

  @sessions_probe """
  case code:ensure_loaded(trace) of
    {module, trace} -> erlang:function_exported(trace, session_create, 3);
    _ -> false
  end.
  """

  # The measuring and ranking both backends share, given Trace (turns the
  # call flag on or off for the profiled processes), Measure (sets, pauses
  # or clears the counters on every pattern, returning how many functions
  # matched) and Info (reads one function's counters).
  @measure ~S"""
  Trace(true),
  N = Measure(true),
  Owner ! {profile_started, self(), N},
  T0 = erlang:monotonic_time(microsecond),
  receive stop -> ok after Duration -> ok end,
  _ = Measure(pause),
  Elapsed = erlang:monotonic_time(microsecond) - T0,
  Trace(false),
  FunsOf = fun(M) ->
    case catch M:module_info(functions) of L when is_list(L) -> L; _ -> [] end
  end,
  Expand = fun({'_', '_', '_'}) -> [{M, F, A} || {M, _} <- code:all_loaded(), {F, A} <- FunsOf(M)];
              ({M, '_', '_'}) -> [{M, F, A} || {F, A} <- FunsOf(M)];
              ({M, F0, '_'}) -> [{M, F, A} || {F, A} <- FunsOf(M), F =:= F0]
           end,
  Bytes = erlang:system_info(wordsize),
  Row = fun(MFA) ->
    case catch Info(MFA, call_time) of
      {call_time, [_ | _] = PerProc} ->
        Mem = case catch Info(MFA, call_memory) of
                {call_memory, [_ | _] = PM} -> lists:sum([W || {_, _, W} <- PM]);
                _ -> 0
              end,
        Calls = lists:sum([C || {_, C, _, _} <- PerProc]),
        [{MFA, Calls, lists:sum([S * 1000000 + U || {_, _, S, U} <- PerProc]), Mem * Bytes,
          [{P, S * 1000000 + U} || {P, _, S, U} <- PerProc]} || Calls > 0];
      _ -> []
    end
  end,
  Rows = [R || MFA <- lists:usort(lists:append([Expand(P) || P <- Patterns])), R <- Row(MFA)],
  ByProc = lists:foldl(fun({_, _, _, _, PP}, Acc) ->
                         lists:foldl(fun({P, Us}, A) -> maps:update_with(P, fun(X) -> X + Us end, Us, A) end,
                                     Acc, PP)
                       end, #{}, Rows),
  Procs5 = [{P, Us, case erlang:process_info(P, registered_name) of
                      {registered_name, Name} -> Name;
                      _ -> undefined
                    end}
            || {P, Us} <- lists:sublist(lists:reverse(lists:keysort(2, maps:to_list(ByProc))), 5)],
  Slim = [{MFA, C, Us, B} || {MFA, C, Us, B, _} <- Rows],
  Owner ! {profile_result, self(),
           #{elapsed_us => Elapsed,
             matched => N,
             called => length(Slim),
             calls => lists:sum([C || {_, C, _, _} <- Slim]),
             time_us => lists:sum([U || {_, _, U, _} <- Slim]),
             memory_bytes => lists:sum([B || {_, _, _, B} <- Slim]),
             by_time => lists:sublist(lists:reverse(lists:keysort(3, Slim)), Top),
             by_memory => lists:sublist(lists:reverse(lists:keysort(4, [R || {_, _, _, B} = R <- Slim, B > 0])), Top),
             by_process => Procs5}}
  """

  @session_holder ~S"""
                  S = trace:session_create(otp_debug_mcp_profile, self(), []),
                  Trace = fun(On) ->
                    case Procs of
                      all -> trace:process(S, all, On, [call]), trace:process(S, self(), false, [call]);
                      _ -> [catch trace:process(S, P, On, [call]) || P <- Procs]
                    end
                  end,
                  Measure = fun(How) -> lists:sum([trace:function(S, P, How, [call_time, call_memory]) || P <- Patterns]) end,
                  Info = fun(MFA, Item) -> trace:info(S, MFA, Item) end,
                  """ <> @measure <> ",\ntrace:session_destroy(S).\n"

  # call_memory is newer than call_time: without it, time only.
  @legacy_holder ~S"""
                 Trace = fun(On) ->
                   case Procs of
                     all -> erlang:trace(all, On, [call, {tracer, self()}]), erlang:trace(self(), false, [call]);
                     _ -> [catch erlang:trace(P, On, [call, {tracer, self()}]) || P <- Procs]
                   end
                 end,
                 Measure = fun(How) ->
                   lists:sum([case catch erlang:trace_pattern(P, How, [call_time, call_memory]) of
                                Matched when is_integer(Matched) -> Matched;
                                _ -> erlang:trace_pattern(P, How, [call_time])
                              end || P <- Patterns])
                 end,
                 Info = fun(MFA, Item) -> erlang:trace_info(MFA, Item) end,
                 try
                 """ <>
                   @measure <>
                   ~S"""
                   after
                     catch Measure(false),
                     catch Trace(false)
                   end.
                   """

  @doc """
  Profile `scope` for `duration_ms`: `{:module, module, function | nil}`,
  or `:all_modules`. Options:

    * `:process` - only this pid's calls (default: every process's)
    * `:top` - how many functions each ranking keeps (default 15)
    * `:force` - on nodes without trace sessions, profile even though other
      tracing is active, ending it
    * `:backend` - `:auto` (default), or `:legacy` to use the legacy trace
      session on a node that has sessions, for testing
  """
  def profile(scope, duration_ms, opts \\ []) do
    top = Keyword.get(opts, :top, 15)
    procs = if pid = opts[:process], do: [pid], else: :all

    with {:ok, patterns} <- patterns(scope),
         {:ok, target} <- Target.target(),
         {:ok, backend} <- backend(Keyword.get(opts, :backend, :auto)),
         :ok <- check_legacy(backend, Keyword.get(opts, :force, false), target) do
      code = if backend == :session, do: @session_holder, else: @legacy_holder

      bindings = [
        Patterns: patterns,
        Procs: procs,
        Duration: duration_ms,
        Top: top,
        Owner: self()
      ]

      with {:ok, result} <- run(target, code, bindings, duration_ms) do
        {:ok, describe(result, backend, procs, duration_ms)}
      end
    end
  end

  defp patterns(:all_modules), do: {:ok, [{:_, :_, :_}]}

  defp patterns({:module, module_str, function_str}) do
    mod = Tracer.resolve_module(module_str)

    case Target.rpc(:code, :is_loaded, [mod]) do
      {:ok, {:file, _}} ->
        fun = if function_str, do: String.to_atom(function_str), else: :_
        {:ok, [{mod, fun, :_}]}

      {:ok, false} ->
        {:error, {:module_not_loaded_on_target, module_str}}

      err ->
        err
    end
  end

  defp backend(:legacy), do: {:ok, :legacy}

  defp backend(:auto) do
    with {:ok, sessions?} <- Checks.remote_eval(@sessions_probe) do
      {:ok, if(sessions?, do: :session, else: :legacy)}
    end
  end

  defp check_legacy(:session, _force, _target), do: :ok

  defp check_legacy(:legacy, force, target) do
    case Tracer.other_tracing() do
      {:ok, nil} ->
        :ok

      {:ok, _other} when force ->
        :ok

      {:ok, other} ->
        {:error,
         %{
           refused: "other tracing is active on #{target}",
           active_tracing: other,
           why:
             "This node predates OTP 27's isolated trace sessions, so profile counts calls " <>
               "in the node's legacy trace session, which this tracing uses too. Starting " <>
               "and clearing the profile would end it. Someone may be debugging this node " <>
               "right now.",
           next_step:
             "Ask the user whether it is OK to stop this tracing. Only if they agree, " <>
               "call profile again with force: true."
         }}

      err ->
        err
    end
  end

  # Spawning the holder sends its code and bindings, and setting counters
  # up may load modules, so that counts toward the tool's footprint.
  # Patterns on every function of a big node can take a while to set.
  defp run(target, code, bindings, duration_ms) do
    {:ok, tokens, _} = :erl_scan.string(String.to_charlist(code))
    {:ok, exprs} = :erl_parse.parse_exprs(tokens)
    bindings = Enum.sort(bindings)

    started =
      Target.with_footprint(
        target,
        {:profile_holder, :erlang.phash2(code)},
        [exprs, bindings],
        fn ->
          Target.note_spawns(target)

          {holder, ref} =
            Target.with_stderr_group_leader(fn ->
              Node.spawn_monitor(target, :erl_eval, :exprs, [exprs, bindings])
            end)

          receive do
            {:profile_started, ^holder, matched} -> {:started, holder, ref, matched}
            {:DOWN, ^ref, :process, _, reason} -> {:down, reason}
          after
            30_000 -> {:timeout, holder, ref}
          end
        end
      )

    case started do
      {:started, holder, ref, 0} ->
        send(holder, :stop)
        Process.demonitor(ref, [:flush])

        {:error,
         "no function matches. The module is loaded on the target, so check the function name."}

      {:started, holder, ref, _matched} ->
        receive do
          {:profile_result, ^holder, result} ->
            Process.demonitor(ref, [:flush])
            {:ok, result}

          {:DOWN, ^ref, :process, _, reason} ->
            {:error, {:profile_failed, reason}}
        after
          duration_ms + 60_000 ->
            send(holder, :stop)
            Process.demonitor(ref, [:flush])
            {:error, "the profile didn't finish in time"}
        end

      {:down, reason} ->
        {:error, {:profile_failed, reason}}

      {:timeout, holder, ref} ->
        send(holder, :stop)
        Process.demonitor(ref, [:flush])
        {:error, "the profile didn't start within 30s"}
    end
  end

  defp describe(r, backend, procs, duration_ms) do
    %{
      backend:
        if(backend == :session,
          do: "isolated trace session",
          else: "legacy trace session (erlang:trace_pattern)"
        ),
      duration_ms: div(r.elapsed_us, 1000),
      requested_ms: duration_ms,
      processes: if(procs == :all, do: "all", else: Enum.map(procs, &Format.inspect/1)),
      functions_profiled: r.matched,
      functions_called: r.called,
      total: %{calls: r.calls, time_us: r.time_us, memory_bytes: r.memory_bytes},
      by_time: Enum.map(r.by_time, &row(&1, r.time_us)),
      by_memory: Enum.map(r.by_memory, &row(&1, r.time_us)),
      by_process:
        for {pid, us, name} <- r.by_process do
          %{pid: Format.inspect(pid), time_us: us, percent: percent(us, r.time_us)}
          |> then(&if name == :undefined, do: &1, else: Map.put(&1, :name, Format.inspect(name)))
        end,
      interpretation: """
      Counts from the runtime's call_time and call_memory counters, the ones
      eprof and tprof use. time_us is a function's own time: time spent in
      another profiled function counts toward that one, time in a function
      that isn't profiled (in another module, say) toward its caller. Only
      time the process spends running counts, not time it waits: in a
      receive, a sleep, or a call to another process. A function that's
      slow because it waits shows little time_us; its calls' timestamps in
      trace_calls show how long they take.
      percent is the share of all profiled time, which adds up across
      processes, so total time_us can exceed the duration on a multi-core
      node. memory_bytes is memory allocated on the heap, counted the same
      way. by_process ranks the processes making the profiled calls. Next
      step: read the code of the functions at the top of by_time; profile
      one function, or one process, to narrow it down.\
      """
    }
  end

  defp row({{m, f, a}, calls, us, bytes}, total_us) do
    %{
      function: name(m, f, a),
      calls: calls,
      time_us: us,
      us_per_call: Float.round(us / calls, 2),
      percent: percent(us, total_us),
      memory_bytes: bytes
    }
  end

  defp percent(_us, 0), do: 0.0
  defp percent(us, total), do: Float.round(100 * us / total, 1)

  # Anonymous functions are compiled to functions named after the one they
  # are in, e.g. -crunch/1-fun-0-/1, and named here as Elixir does.
  defp name(m, f, a) do
    case Regex.run(~r{^-(.+)/(\d+)-fun-\d+-$}, to_string(f)) do
      [_, outer, outer_arity] -> "anonymous fn/#{a} in #{name(m, outer, outer_arity)}"
      nil -> mfa(m, f, a)
    end
  end

  defp mfa(m, f, a) do
    case Atom.to_string(m) do
      "Elixir." <> elixir -> "#{elixir}.#{f}/#{a}"
      erlang -> "#{erlang}:#{f}/#{a}"
    end
  end
end
