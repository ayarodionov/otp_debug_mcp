defmodule OtpDebugMcp.Benchmark do
  @moduledoc """
  A function measured on the node, and compared with others: each called
  with the same arguments, repeatedly, in fresh processes, for a while.

  For each function (and each set of spawn options, to try a process's
  tuning, such as a larger `min_heap_size`), the time per call (p50, p95,
  p99, mean, max), the reductions per call, the calls a second across
  `concurrency` processes calling at once, and whether every variant gave
  the same result as the first: a tuned version that's faster but
  answers differently isn't a tuning.

  It runs in a process of its own on the node, started and then read
  back, as calls to the node are made one at a time. The arguments are
  an Erlang expression, evaluated once there, so every call gets the
  same terms.
  """

  alias OtpDebugMcp.{Checks, Format}

  @start ~S"""
  case whereis(Name) of
    undefined ->
      Parse = fun(Text0) ->
        %% An expression, with its full stop added if it hasn't one.
        Text = case lists:reverse(string:trim(Text0)) of
          [$. | _] -> Text0;
          _ -> Text0 ++ "."
        end,
        {ok, Tokens, _} = erl_scan:string(Text),
        {ok, Exprs} = erl_parse:parse_exprs(Tokens),
        {value, V, _} = erl_eval:exprs(Exprs, []),
        V
      end,
      case catch {Parse(ArgsText), [Parse(O) || O <- OptsTexts]} of
        {Args, Optss} when is_list(Args) ->
          Parent = self(),
          %% One worker: calls until the deadline or Runs calls, timing each.
          Worker = fun(M, F, Coordinator, Until) ->
            fun() ->
              First = (catch {ok, apply(M, F, Args)}),
              Loop = fun L(N, Times, Reds, Errors) ->
                case N >= Runs orelse erlang:monotonic_time(millisecond) >= Until of
                  true -> {N, Times, Reds, Errors};
                  false ->
                    {reductions, R0} = erlang:process_info(self(), reductions),
                    T0 = erlang:monotonic_time(nanosecond),
                    Ok = case catch apply(M, F, Args) of {'EXIT', _} -> false; _ -> true end,
                    T1 = erlang:monotonic_time(nanosecond),
                    {reductions, R1} = erlang:process_info(self(), reductions),
                    Times2 = case N < 100000 of true -> [T1 - T0 | Times]; false -> Times end,
                    L(N + 1, Times2, Reds + (R1 - R0),
                      case Ok of true -> Errors; false -> Errors + 1 end)
                end
              end,
              {Calls, Times, Reds, Errors} = Loop(0, [], 0, 0),
              {total_heap_size, Heap} = erlang:process_info(self(), total_heap_size),
              Coordinator ! {done, self(), First, Calls, Times, Reds, Errors, Heap}
            end
          end,
          Run = fun({M, F}, Opts) ->
            Until = erlang:monotonic_time(millisecond) + Duration,
            T0 = erlang:monotonic_time(millisecond),
            Pids = [element(1, spawn_opt(Worker(M, F, self(), Until), [monitor | Opts]))
                    || _ <- lists:seq(1, Concurrency)],
            Results = [receive
                         {done, P, First, Calls, Times, Reds, Errors, Heap} -> {First, Calls, Times, Reds, Errors, Heap};
                         {'DOWN', _, process, P, Why} -> {{'EXIT', Why}, 0, [], 0, 0, 0}
                       after Duration + 10000 -> {timeout, 0, [], 0, 0, 0}
                       end || P <- Pids],
            Wall = erlang:monotonic_time(millisecond) - T0,
            {{M, F}, Opts, Wall, Results}
          end,
          spawn(fun() ->
            register(Name, self()),
            Parent ! {Name, started},
            Out = [Run(MF, Opts) || MF <- Functions, Opts <- Optss],
            receive {read, From, Ref} -> From ! {Ref, Out} after 60000 -> ok end
          end),
          receive {Name, started} -> started after 5000 -> timeout end;
        {'EXIT', Why} ->
          {bad_args, Why};
        Other ->
          {bad_args, {not_a_list, Other}}
      end;
    _ ->
      already_running
  end.
  """

  @read ~S"""
  case whereis(Name) of
    undefined -> none;
    Pid ->
      Ref = make_ref(),
      Pid ! {read, self(), Ref},
      receive {Ref, Out} -> {ok, Out} after Wait -> timeout end
  end.
  """

  @name :otp_debug_mcp_benchmark

  @doc """
  Measure `functions` (each "mod:fun" or "Elixir.Mod.fun"), called with
  `args` (an Erlang expression for the list of arguments), under each of
  `spawn_options` (Erlang expressions for spawn_opt option lists).
  """
  def report(functions, args, opts) do
    spawn_options = opts[:spawn_options] || ["[]"]
    variants = length(functions) * length(spawn_options)
    # Each variant gets its share of the time calls to the node may take.
    duration = min(opts[:duration_ms] || 2_000, div(12_000, max(variants, 1)))

    with {:ok, mfs} <- parse_functions(functions),
         {:ok, :started} <-
           started(
             Checks.remote_eval(@start,
               Name: @name,
               ArgsText: String.to_charlist(args),
               OptsTexts: Enum.map(spawn_options, &String.to_charlist/1),
               Functions: mfs,
               Duration: duration,
               Runs: opts[:runs] || 100_000,
               Concurrency: opts[:concurrency] || 1
             )
           ),
         {:ok, {:ok, out}} <- Checks.remote_eval(@read, Name: @name, Wait: 14_000) do
      {:ok, analyze(out, spawn_options, duration)}
    else
      {:ok, :timeout} -> {:error, "the benchmark didn't finish in time"}
      {:error, _} = err -> err
      other -> {:error, Format.inspect(other, limit: 20)}
    end
  end

  defp started({:ok, :started}), do: {:ok, :started}

  defp started({:ok, :already_running}),
    do: {:error, "a benchmark is already running on this node"}

  defp started({:ok, {:bad_args, why}}),
    do:
      {:error,
       "args must be an Erlang expression for the list of arguments, e.g. \"[42, <<\\\"x\\\">>]\" or \"[quote:sample_order(100)]\": #{Format.inspect(why, limit: 10)}"}

  defp started(other), do: other

  # "mod:fun", "Elixir.Mod.fun" or "Mod.fun" (an Elixir module).
  defp parse_functions(functions) do
    parsed =
      for text <- functions do
        case String.split(text, ":") do
          [m, f] when m != "" and f != "" ->
            {String.to_atom(m), String.to_atom(f)}

          [_] ->
            case String.split(text, ".") do
              parts when length(parts) >= 2 ->
                {f, m} = List.pop_at(parts, -1)
                m = Enum.join(m, ".")
                m = if String.starts_with?(m, "Elixir."), do: m, else: "Elixir." <> m
                {String.to_atom(m), String.to_atom(f)}

              _ ->
                {:error, text}
            end

          _ ->
            {:error, text}
        end
      end

    case Enum.find(parsed, &match?({:error, _}, &1)) do
      nil ->
        {:ok, parsed}

      {:error, text} ->
        {:error, "#{text}: give a function as mod:fun (Erlang) or Mod.fun (Elixir)"}
    end
  end

  # -- Analysis ------------------------------------------------------------------

  defp analyze(out, spawn_options, duration) do
    opts_text = Map.new(Enum.zip(Enum.uniq(for({_, o, _, _} <- out, do: o)), spawn_options))

    variants =
      for {{m, f}, opts, wall, results} <- out do
        times = results |> Enum.flat_map(&elem(&1, 2)) |> Enum.sort()
        calls = results |> Enum.map(&elem(&1, 1)) |> Enum.sum()
        reds = results |> Enum.map(&elem(&1, 3)) |> Enum.sum()
        errors = results |> Enum.map(&elem(&1, 4)) |> Enum.sum()
        first = results |> List.first() |> elem(0)

        %{
          function: mfa({m, f}),
          spawn_options: Map.get(opts_text, opts, Format.inspect(opts)),
          calls: calls,
          calls_per_s: Float.round(calls * 1000 / max(wall, 1), 1),
          reductions_per_call: if(calls > 0, do: div(reds, calls), else: nil),
          errors: errors,
          heap_words_after: results |> Enum.map(&elem(&1, 5)) |> Enum.max(fn -> 0 end)
        }
        |> Map.merge(timing(times))
        |> Map.put(:result, result(first))
        |> Map.put(:first, first)
      end

    baseline = hd(variants)

    variants =
      for {v, i} <- Enum.with_index(variants) do
        v
        |> Map.put(:same_result_as_first, same?(v.first, baseline.first))
        |> put(:speedup_vs_first, i > 0 && speedup(baseline, v))
        |> Map.delete(:first)
      end

    notes = findings(variants)

    %{
      status: if(Enum.any?(notes, &(elem(&1, 0) == :warning)), do: :warning, else: :ok),
      findings: for({level, text} <- notes, do: "#{level}: #{text}"),
      duration_ms_each: duration,
      variants: variants,
      interpretation: interpretation()
    }
  end

  defp timing([]), do: %{}

  defp timing(sorted) do
    n = length(sorted)
    at = fn p -> Enum.at(sorted, min(n - 1, floor(p * n))) end
    us = fn ns -> Float.round(ns / 1000, 1) end

    %{
      us_p50: us.(at.(0.5)),
      us_p95: us.(at.(0.95)),
      us_p99: us.(at.(0.99)),
      us_max: us.(List.last(sorted)),
      us_mean: us.(Enum.sum(sorted) / n)
    }
  end

  # A preview of the result: a long string or list would swamp the report.
  defp result({:ok, value}) do
    text = Format.inspect(value, limit: 8, printable_limit: 120)
    text = if String.length(text) > 300, do: String.slice(text, 0, 300) <> "...", else: text
    %{ok: text, words: :erts_debug.flat_size(value)}
  end

  defp result(other), do: %{error: Format.inspect(other, limit: 10)}

  defp same?({:ok, a}, {:ok, b}), do: a === b
  defp same?(_, _), do: false

  defp speedup(%{us_mean: a}, %{us_mean: b}) when b > 0, do: Float.round(a / b, 2)

  defp speedup(_, _), do: nil

  defp mfa({m, f}) do
    name = Atom.to_string(m)

    if String.starts_with?(name, "Elixir."),
      do: "#{String.replace_prefix(name, "Elixir.", "")}.#{f}",
      else: "#{name}:#{f}"
  end

  defp findings(variants) do
    differ =
      for v <- tl(variants), not v.same_result_as_first do
        {:warning,
         "#{v.function} (#{v.spawn_options}) didn't return the same as #{hd(variants).function}: not equivalent, so not a tuning of it"}
      end

    errors =
      for v <- variants, v.errors > 0 or Map.has_key?(v.result, :error) do
        {:warning,
         "#{v.function} (#{v.spawn_options}) failed: #{v.errors} calls raised#{if v.result[:error], do: ", the first: #{v.result.error}", else: ""}"}
      end

    # Among the variants that answer as the first does: the others aren't
    # tunings of it.
    best =
      case Enum.filter(
             variants,
             &(is_number(&1[:us_mean]) and &1.same_result_as_first and &1.errors == 0)
           ) do
        [_, _ | _] = timed ->
          fastest = Enum.min_by(timed, & &1.us_mean)
          slowest = Enum.max_by(timed, & &1.us_mean)

          [
            {:info,
             "fastest: #{fastest.function} (#{fastest.spawn_options}), #{fastest.us_mean} µs a call on average, #{Float.round(slowest.us_mean / max(fastest.us_mean, 0.001), 1)} times faster than #{slowest.function} (#{slowest.spawn_options})"}
          ]

        _ ->
          []
      end

    differ ++ errors ++ best
  end

  defp put(map, _key, value) when value in [nil, false], do: map
  defp put(map, key, value), do: Map.put(map, key, value)

  defp interpretation do
    """
    variants are each function under each set of spawn options, called
    with the same arguments by concurrency fresh processes for
    duration_ms_each. Times are per call, in µs (p50, p95, p99, mean,
    max); reductions_per_call is the work the scheduler counted, a
    measure that doesn't depend on the machine's load; calls_per_s is
    across all the processes; heap_words_after, the largest worker's heap
    at the end. same_result_as_first checks a variant gave exactly the
    first one's result (shown in result, with its size in words), and
    speedup_vs_first compares the mean time. A larger min_heap_size in
    spawn_options means fewer garbage collections for a function that
    allocates a lot; fullsweep_after and message_queue_data are other
    process settings worth trying there. Next step: for a rewritten
    version, compile it as a module of another name, load it with
    load_module, and benchmark both.
    """
  end
end
