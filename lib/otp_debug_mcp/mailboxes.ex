defmodule OtpDebugMcp.Mailboxes do
  @moduledoc """
  The processes with long mailboxes, and for each what a mailbox's length
  alone doesn't say: whether it grows (two readings a second apart), where
  it is in its code (the top of its stack, and the first frame that isn't
  OTP's or Elixir's own), and the memory it holds.

  For the longest mailbox it also finds who fills it. On OTP 27 and later a
  trace session of its own traces sends, of every process, with a match
  specification that keeps only those to that process, so only they cost
  a trace message; it counts them by sender and by the message's shape,
  for at most `@trace_ms`, and stops at `@trace_events`. Older nodes have
  no isolated sessions, and the senders aren't measured there.
  """

  alias OtpDebugMcp.{Checks, Format}

  @min_queue 1_000
  @critical_queue 100_000
  @interval_ms 1_000
  @trace_ms 300
  @trace_events 1_000
  @max_senders 3

  @sample ~S"""
  Read = fun(P) ->
    case erlang:process_info(P, message_queue_len) of
      {_, Q} -> {Q, ok};
      _ -> gone
    end
  end,
  Sh = fun(T) when is_atom(T) -> {atom, T};
          (T) when is_tuple(T), tuple_size(T) > 0, is_atom(element(1, T)) -> {element(1, T), tuple_size(T)};
          (T) when is_tuple(T) -> {tuple, tuple_size(T)};
          (T) when is_list(T) -> list;
          (T) when is_binary(T) -> binary;
          (T) when is_map(T) -> map;
          (_) -> other
       end,
  Shape = fun({'$gen_cast', M}) -> {cast, Sh(M)};
             ({'$gen_call', _, M}) -> {call, Sh(M)};
             (M) -> {info, Sh(M)}
          end,
  Now = fun() -> erlang:monotonic_time(millisecond) end,
  T0 = Now(),
  First = [{P, Read(P)} || P <- Pids],
  Sessions = code:ensure_loaded(trace) =:= {module, trace}
             andalso erlang:function_exported(trace, session_create, 3),
  Senders = case {Sessions, Pids} of
    _ when not Watch -> not_watched;
    {false, _} -> no_sessions;
    {true, []} -> none;
    {true, [Top | _]} ->
      Names = case erlang:process_info(Top, registered_name) of
        {registered_name, Reg} when is_atom(Reg) -> [Reg];
        _ -> []
      end,
      S = trace:session_create(otp_debug_mcp_senders, self(), []),
      %% The pattern first: until it's set, every send would match.
      trace:send(S, [{[To, '_'], [], []} || To <- [Top | Names]], []),
      trace:process(S, all, true, [send]),
      Start = Now(),
      Deadline = Start + TraceMs,
      Collect = fun C(N, Acc) when N >= MaxEvents -> {N, Acc};
                    C(N, Acc) ->
                      receive
                        {trace, From, send, Msg, _} ->
                          C(N + 1, maps:update_with({From, Shape(Msg)}, fun(V) -> V + 1 end, 1, Acc))
                      after max(0, Deadline - Now()) -> {N, Acc}
                      end
                end,
      {Events, Counts} = Collect(0, #{}),
      Elapsed = Now() - Start,
      trace:session_destroy(S),
      Flush = fun F() -> receive {trace, _, send, _, _} -> F() after 0 -> ok end end,
      Flush(),
      Who = lists:usort([From || {From, _} <- maps:keys(Counts)]),
      {Events, Elapsed, maps:to_list(Counts),
       [{P, Initial(P), catch erlang:process_info(P, [registered_name, current_function])}
        || P <- Who, is_pid(P)]}
  end,
  timer:sleep(max(0, Interval - (Now() - T0))),
  T1 = Now(),
  Second = [{P, Read(P)} || P <- Pids],
  %% Which modules are OTP's or Elixir's own, as in hot_spots.
  Roots = [code:root_dir() | case code:lib_dir(elixir) of
                               {error, _} -> [];
                               Dir -> [filename:dirname(Dir)]
                             end],
  Own = fun(M) ->
    case code:which(M) of
      preloaded -> true;
      Path when is_list(Path) -> lists:any(fun(R) -> lists:prefix(R, Path) end, Roots);
      _ -> false
    end
  end,
  Where = fun(P) ->
    case erlang:process_info(P, [memory, status, current_stacktrace]) of
      [{_, Mem}, {_, Status}, {_, Stack}] ->
        Yours = case [F || {M, _, _, _} = F <- Stack, not Own(M)] of
          [F | _] -> F;
          [] -> undefined
        end,
        {Mem, Status, case Stack of [Top1 | _] -> Top1; [] -> undefined end, Yours};
      _ -> gone
    end
  end,
  {T1 - T0, First, Second, [{P, Where(P)} || P <- Pids], Senders}.
  """

  @doc """
  The message_queues check: `{:ok, status, findings, interpretation}` or an
  error. With `senders: false`, who sends to the longest mailbox isn't
  traced.
  """
  def run(opts \\ []) do
    with {:ok, top} <- OtpDebugMcp.Target.rpc(:recon, :proc_count, [:message_queue_len, 10]),
         long = for({pid, qlen, info} <- top, qlen > @min_queue, do: {pid, qlen, info}),
         {:ok, sampled} <- sample(Enum.map(long, &elem(&1, 0)), Keyword.get(opts, :senders, true)) do
      offenders = Enum.map(long, &offender(&1, sampled))

      status =
        cond do
          Enum.any?(offenders, &(&1.queue_len > @critical_queue)) -> :critical
          offenders != [] -> :warning
          true -> :ok
        end

      {:ok, status, offenders, interpretation()}
    end
  end

  defp sample([], _watch), do: {:ok, nil}

  defp sample(pids, watch) do
    code = Checks.supervisor_funs() <> Checks.initial_call_fun() <> @sample

    bindings = [
      Pids: pids,
      Watch: watch,
      Interval: @interval_ms,
      TraceMs: @trace_ms,
      MaxEvents: @trace_events
    ]

    with {:ok, {elapsed_ms, first, second, where, senders}} <-
           Checks.remote_eval(code, bindings) do
      {:ok,
       %{
         elapsed_ms: max(elapsed_ms, 1),
         first: Map.new(first),
         second: Map.new(second),
         where: Map.new(where),
         senders: senders,
         traced: List.first(pids)
       }}
    end
  end

  defp offender({pid, qlen, info}, sampled) do
    %{pid: Format.inspect(pid), queue_len: qlen, info: Checks.format_proc_info(pid, info)}
    |> Map.merge(trend(sampled.first[pid], sampled.second[pid], sampled.elapsed_ms))
    |> Map.merge(where(sampled.where[pid]))
    |> Map.merge(if pid == sampled.traced, do: senders(sampled.senders), else: %{})
  end

  # The mailbox's growth between the two readings. (The process's
  # reductions would say whether it ran at all, but other checks' reads
  # and garbage collections cost it reductions too.)
  defp trend({q0, _}, {q1, _}, elapsed_ms),
    do: %{queue_len: q1, growth_per_s: round((q1 - q0) * 1000 / elapsed_ms)}

  defp trend(_, _, _), do: %{exited_during_check: true}

  defp where({memory, status, top, yours}) do
    %{memory_bytes: memory, status: status}
    |> put(:in, frame(top))
    |> put(:called_from, if(yours != top, do: frame(yours)))
  end

  defp where(_), do: %{}

  defp senders(:not_watched),
    do: %{senders: "not measured: diagnose ran with quick, which traces nothing"}

  defp senders(:no_sessions),
    do: %{
      senders:
        "not measured: this node predates OTP 27's trace sessions. trace_calls on the " <>
          "function that sends (GenServer cast or call, gen_server, erlang send) names the senders"
    }

  defp senders({0, elapsed_ms, _, _}),
    do: %{senders: [], senders_watched_ms: elapsed_ms}

  defp senders({events, elapsed_ms, counts, who}) do
    who = Map.new(who, fn {pid, initial, info} -> {pid, {initial, info}} end)

    by_sender =
      counts
      |> Enum.group_by(fn {{from, _shape}, _n} -> from end, fn {{_, shape}, n} -> {shape, n} end)
      |> Enum.map(fn {from, shapes} ->
        {from, shapes, shapes |> Enum.map(&elem(&1, 1)) |> Enum.sum()}
      end)
      |> Enum.sort_by(fn {_, _, n} -> -n end)

    %{
      senders:
        for {from, shapes, n} <- Enum.take(by_sender, @max_senders) do
          {shape, _} = Enum.max_by(shapes, &elem(&1, 1))

          %{
            pid: Format.inspect(from),
            share: Float.round(n / events, 2),
            messages_per_s: round(n * 1000 / max(elapsed_ms, 1)),
            sends: shape(shape)
          }
          |> Map.merge(describe(who[from]))
        end,
      sending_processes: length(by_sender),
      senders_watched_ms: elapsed_ms
    }
    |> put(:senders_stopped_early, if(events >= @trace_events, do: "at #{events} messages"))
  end

  defp senders(_), do: %{}

  defp describe({initial, info}) when is_list(info) do
    %{}
    |> put(:name, name(info[:registered_name]))
    |> put(:initial_call, initial != :undefined && initial && Format.inspect(initial))
    |> put(:current_function, Format.inspect(info[:current_function]))
  end

  defp describe(_), do: %{}

  defp name(name) when is_atom(name) and name not in [nil, []], do: Format.inspect(name)
  defp name(_), do: nil

  # A message's shape as Shape/1 gives it: how it was sent, and its tag and
  # size, never its content.
  defp shape({kind, shape}), do: "#{kind_text(kind)} #{shape_text(shape)}"

  defp kind_text(:cast), do: "casts"
  defp kind_text(:call), do: "calls"
  defp kind_text(:info), do: "messages"

  defp shape_text({:atom, atom}) when is_atom(atom), do: Format.inspect(atom)
  defp shape_text({:tuple, n}), do: "{" <> Enum.join(List.duplicate("_", n), ", ") <> "}"

  defp shape_text({tag, n}),
    do: "{" <> Enum.join([Format.inspect(tag) | List.duplicate("_", n - 1)], ", ") <> "}"

  defp shape_text(:list), do: "(a list)"
  defp shape_text(:binary), do: "(a binary)"
  defp shape_text(:map), do: "(a map)"
  defp shape_text(_), do: "(another term)"

  defp frame({m, f, a, location}) do
    arity = if is_list(a), do: length(a), else: a
    separator = if elixir?(m), do: ".", else: ":"
    "#{module(m)}#{separator}#{f}/#{arity}" <> location(location)
  end

  defp frame(_), do: nil

  defp location(location) do
    case {location[:file], location[:line]} do
      {nil, _} -> ""
      {file, nil} -> " (#{file})"
      {file, line} -> " (#{file}:#{line})"
    end
  end

  defp module(m), do: if(elixir?(m), do: Kernel.inspect(m), else: Atom.to_string(m))
  defp elixir?(m), do: String.starts_with?(Atom.to_string(m), "Elixir.")

  defp put(map, _key, nil), do: map
  defp put(map, _key, false), do: map
  defp put(map, key, value), do: Map.put(map, key, value)

  defp interpretation do
    """
    Processes with message_queue_len > #{@min_queue}. growth_per_s is the
    mailbox's change over a second: positive, messages arrive faster than
    the process handles them; zero with no senders, it took no message
    and none arrived, so it isn't reading them (blocked where `in` says,
    or in a receive that matches none of them). `in` is
    the top of its stack and called_from the first frame outside OTP's and
    Elixir's own code: the place in your code it spends its time.
    senders, for the longest mailbox, are the processes that sent to it
    during senders_watched_ms, by share of the messages, with the shape of
    what they send (the tag and size, not the content). Their
    messages_per_s is extrapolated from that short window, which a burst
    can fill: growth_per_s, over a full second, is the rate to rely on, and
    the two can't be subtracted to get what the process handles. Next step:
    process_info on the offender, call_latency for its time per message,
    module_code for the code at called_from. Fixes: make the sender wait
    (a call instead of a cast, or acknowledged batches), take the slow
    work out of the process, or spread it over several.
    """
  end
end
