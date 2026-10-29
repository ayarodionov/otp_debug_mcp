defmodule OtpDebugMcp.HotSpots do
  @moduledoc """
  Where a node's CPU goes, by function, from sampling stacks: a sampling
  profiler, with no tracing, so nothing on the node runs slower for it.

  The busiest processes first, by reductions over a short look (recon's
  proc_window); then, through the window, their stacks every few
  milliseconds, kept when the process is running or runnable (it wants
  the CPU) or collecting garbage; and every half second a scan of all
  processes for running ones, to catch busy short-lived processes. A
  function's share of those samples is about its share of the CPU time
  they use: at the top of the stack, its own time; anywhere in it, its
  time with what it calls. The first frame outside OTP and Elixir is
  where your code is.

  `profile` then counts calls and time exactly, in the module this
  points to; `benchmark` measures a function, and compares a tuned one.
  """

  alias OtpDebugMcp.{Checks, Format}

  @sample ~S"""
  Deadline = erlang:monotonic_time(millisecond) + Duration,
  %% The busiest processes, by reductions over a short look.
  Look = max(200, min(1000, Duration div 4)),
  Top0 = case catch recon:proc_window(reductions, 40, Look) of
    L when is_list(L) -> [P || {P, R, _} <- L, is_pid(P), R > 0];
    _ -> []
  end,
  Frames = fun(St) -> [{M, F, case is_list(A) of true -> length(A); false -> A end} || {M, F, A, _} <- St] end,
  Me = self(),
  Scan = fun(Known) ->
    New = [P || P <- lists:sublist(erlang:processes(), MaxProcs), P =/= Me,
                not lists:member(P, Known),
                erlang:process_info(P, status) =:= {status, running}],
    lists:sublist(Known ++ New, 200)
  end,
  Loop = fun L(Watched, N, Acc, Gc) ->
    case erlang:monotonic_time(millisecond) >= Deadline of
      true -> {lists:reverse(Acc), Gc, N, Watched};
      false ->
        W = case N rem 50 of 0 -> Scan(Watched); _ -> Watched end,
        {Acc2, Gc2} = lists:foldl(
          fun(P, {A, G}) ->
            case erlang:process_info(P, [status, current_stacktrace]) of
              [{status, S}, {current_stacktrace, St}] when S =:= running; S =:= runnable ->
                {[{P, Frames(St)} | A], G};
              [{status, garbage_collecting}, _] ->
                {A, G + 1};
              _ -> {A, G}
            end
          end, {Acc, Gc}, W),
        timer:sleep(Interval),
        L(W, N + 1, Acc2, Gc2)
    end
  end,
  {Samples, Gc, Rounds, Watched} = Loop(Top0, 0, [], 0),
  %% Which modules are OTP's or Elixir's own: under OTP's root, or next to
  %% Elixir's standard library.
  Roots = [code:root_dir() | case code:lib_dir(elixir) of
                               {error, _} -> [];
                               Dir -> [filename:dirname(Dir)]
                             end],
  Mods = lists:usort([M || {_, Fs} <- Samples, {M, _, _} <- Fs]),
  Own = [M || M <- Mods,
              case code:which(M) of
                preloaded -> true;
                Path when is_list(Path) -> lists:any(fun(R) -> lists:prefix(R, Path) end, Roots);
                _ -> false
              end],
  Who = [{P, catch erlang:process_info(P, [registered_name, initial_call, dictionary])}
         || P <- lists:usort([P || {P, _} <- Samples])],
  {ok, Samples, Gc, Rounds, length(Watched), Own,
   [{P, case I of
          L2 when is_list(L2) ->
            {proplists:get_value(registered_name, L2, []),
             proplists:get_value('$initial_call', proplists:get_value(dictionary, L2, []),
                                 proplists:get_value(initial_call, L2))};
          _ -> gone
        end} || {P, I} <- Who],
   erlang:system_info(schedulers_online)}.
  """

  @doc "Sample the node's busy stacks for `duration_ms`."
  def report(duration_ms) do
    case Checks.remote_eval(@sample, Duration: duration_ms, Interval: 10, MaxProcs: 20_000) do
      {:ok, {:ok, samples, gc, rounds, watched, own, who, schedulers}} ->
        {:ok,
         analyze(
           samples,
           gc,
           rounds,
           watched,
           MapSet.new(own),
           Map.new(who),
           schedulers,
           duration_ms
         )}

      {:ok, other} ->
        {:error, Format.inspect(other, limit: 20)}

      {:error, _} = err ->
        err
    end
  end

  # -- Analysis ------------------------------------------------------------------

  defp analyze(samples, gc, rounds, watched, own, who, schedulers, duration_ms) do
    busy = length(samples)
    share = fn n -> Float.round(n * 100 / max(busy + gc, 1), 1) end

    # The function at the top of each stack: its own time.
    self_time =
      samples
      |> Enum.flat_map(fn {_, frames} -> Enum.take(frames, 1) end)
      |> top(12)
      |> Enum.map(fn {f, n} -> %{function: mfa(f), percent: share.(n)} end)

    # Each function anywhere in the stack, once per sample: its time with
    # what it calls.
    with_callees =
      samples
      |> Enum.flat_map(fn {_, frames} -> Enum.uniq(frames) end)
      |> top(12)
      |> Enum.map(fn {f, n} -> %{function: mfa(f), percent: share.(n)} end)

    # The first frame of your code: where, in it, the time goes.
    yours =
      samples
      |> Enum.map(fn {_, frames} ->
        Enum.find(frames, &(not MapSet.member?(own, elem(&1, 0))))
      end)
      |> top(10)
      |> Enum.map(fn
        {nil, n} -> %{function: "only OTP's or Elixir's code in the stack", percent: share.(n)}
        {f, n} -> %{function: mfa(f), percent: share.(n)}
      end)

    paths =
      samples
      |> Enum.map(fn {_, frames} -> frames |> Enum.take(5) |> Enum.map_join(" <- ", &mfa/1) end)
      |> top(5)
      |> Enum.map(fn {path, n} -> %{stack: path, percent: share.(n)} end)

    processes =
      samples
      |> Enum.map(&elem(&1, 0))
      |> top(8)
      |> Enum.map(fn {pid, n} ->
        %{pid: Format.inspect(pid), percent: share.(n)}
        |> put(:name, name(who[pid]))
        |> put(:initial_call, initial_call(who[pid]))
      end)

    report = %{
      window_ms: duration_ms,
      sampling_rounds: rounds,
      processes_watched: watched,
      busy_samples: busy,
      gc_samples: gc,
      gc_percent: share.(gc),
      schedulers_online: schedulers,
      self_time: self_time,
      with_callees: with_callees,
      your_code: yours,
      hot_paths: paths,
      busiest_processes: processes
    }

    notes = findings(report)

    report
    |> Map.put(:status, status(notes))
    |> Map.put(:findings, for({level, text} <- notes, do: "#{level}: #{text}"))
    |> Map.put(:interpretation, interpretation())
  end

  defp top(list, n) do
    list |> Enum.frequencies() |> Enum.sort_by(fn {_, c} -> -c end) |> Enum.take(n)
  end

  defp name({name, _}) when is_atom(name) and name != [], do: Format.inspect(name)
  defp name(_), do: nil

  defp initial_call({_, {m, f, a}}), do: mfa({m, f, a})
  defp initial_call(_), do: nil

  defp mfa({m, f, a}), do: "#{module(m)}#{if elixir?(m), do: ".", else: ":"}#{f}/#{a}"
  defp mfa(other), do: Format.inspect(other)

  defp module(m) when is_atom(m),
    do: if(elixir?(m), do: Format.inspect(m), else: Atom.to_string(m))

  defp module(m), do: Format.inspect(m)

  defp elixir?(m), do: is_atom(m) and String.starts_with?(Atom.to_string(m), "Elixir.")

  # -- Findings ------------------------------------------------------------------

  defp findings(%{busy_samples: busy, gc_samples: gc}) when busy + gc < 20,
    do: [
      {:info,
       "few busy samples (#{busy + gc}): the node had little CPU work in the window, so there's no hot spot to find; sample while it's under load"}
    ]

  defp findings(r) do
    hot =
      case r.self_time do
        [%{percent: p} = f | _] when p >= 20 ->
          from =
            case r.your_code do
              [%{function: y} | _] when y != f.function -> ", most of it under #{y}"
              _ -> ""
            end

          [
            {:warning,
             "#{p}% of the busy samples are in #{f.function}#{from}: profile that module for calls and time per function, then benchmark it"}
          ]

        _ ->
          []
      end

    # Your code's first frame, when the hot function isn't already it.
    top_self = match?([%{percent: p} | _] when p >= 20, r.self_time) && hd(r.self_time).function

    yours =
      case r.your_code do
        [%{percent: p, function: f} | _] when p >= 30 and f != top_self ->
          [
            {:info,
             "#{p}% of the busy samples are under #{f}, your code's first frame in their stacks"}
          ]

        _ ->
          []
      end

    gc =
      if r.gc_percent >= 15,
        do: [
          {:warning,
           "#{r.gc_percent}% of the samples caught a process collecting garbage: it allocates a lot (build less, or in fewer steps), or its heap starts too small for what it does (spawn it with a larger min_heap_size; benchmark with spawn_options to see)"}
        ],
        else: []

    hot ++ yours ++ gc
  end

  defp status(notes) do
    if Enum.any?(notes, &(elem(&1, 0) == :warning)), do: :warning, else: :ok
  end

  defp put(map, _key, value) when value in [nil, false], do: map
  defp put(map, key, value), do: Map.put(map, key, value)

  defp interpretation do
    """
    busy_samples are the stacks caught running or runnable (wanting the
    CPU) in the window, gc_samples processes caught collecting garbage.
    Shares are of those samples, so of the CPU time they use, not of the
    node's: a node mostly idle has few samples. self_time is the function
    at the top of the stack: where the CPU actually is (lists:nth/2, an
    ETS call, binary matching). with_callees counts a function anywhere
    in the stack, so it's its time with everything it calls. your_code
    is the first frame outside OTP's and Elixir's own code: the place in
    your code to change. hot_paths are the top five frames of the most
    common stacks. Stacks are 8 frames deep at most. Next step: profile
    on the module in your_code, for exact calls and time per function;
    module_code on the function; benchmark it, with a rewritten version
    loaded (load_module) under another name to compare, and with
    spawn_options to try a larger min_heap_size when gc is high.
    """
  end
end
