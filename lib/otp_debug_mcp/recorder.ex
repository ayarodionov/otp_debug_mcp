defmodule OtpDebugMcp.Recorder do
  @moduledoc """
  A flight recorder: a process on the node that samples it every few
  seconds and keeps the last of the samples, so that an agent connecting
  after an incident can read what the node did before.

  Each sample is bounded: memory by category (without the recorder's
  own); the process,
  port and atom counts and the run queue; the five processes with the
  most memory, the longest mailboxes and the most reductions over a
  second (recon's `proc_count` and `proc_window`), each with its name,
  initial call and current function at the time, as pids alone mean
  little later; and the five largest ETS tables.

  Nothing is loaded onto the node. The recorder is a process spawned from
  evaluated code and registered as `otp_debug_mcp_recorder`. It records
  for the time it was started for, then stops sampling and keeps what it
  recorded readable for `@grace_ms` more, then exits; `stop/0` ends it
  at once. It runs whether or not this tool is connected, and is lost if
  the node restarts.

  `history/2` turns the samples into conclusions: what rose or fell, from
  when to when, and which processes and tables did it.
  """

  alias OtpDebugMcp.{Checks, Format}

  @name :otp_debug_mcp_recorder
  @top 5
  # What it recorded stays readable this long after recording ends.
  @grace_ms 24 * 3_600_000

  @start ~S"""
  case whereis(Name) of
    W when is_pid(W) -> already_running;
    undefined ->
      Parent = self(),
      Ref = make_ref(),
      Recorder = fun() ->
        case catch register(Name, self()) of
          true ->
            %% Its own group leader, not that of the call that started it,
            %% which is on the node that called.
            case whereis(user) of U when is_pid(U) -> group_leader(U, self()); _ -> ok end,
            Me = self(),
            %% proc_lib's for its processes; translate_initial_call/1
            %% would answer {proc_lib, init_p, 5} for the others.
            Initial = fun(P) ->
              case erlang:process_info(P, [dictionary, initial_call]) of
                [{dictionary, D}, {initial_call, I}] ->
                  case lists:keyfind('$initial_call', 1, D) of
                    {_, {_, _, _} = PI} -> PI;
                    _ -> I
                  end;
                _ -> undefined
              end
            end,
            Describe = fun(Rows) ->
              [{P, V, Initial(P),
                case erlang:process_info(P, [registered_name, current_function]) of
                  [{registered_name, N}, {current_function, C}] -> {N, C};
                  _ -> gone
                end} || {P, V, _} <- Rows, P =/= Me]
            end,
            Top = fun(Rows) when is_list(Rows) -> Describe(Rows); (_) -> [] end,
            Word = erlang:system_info(wordsize),
            Tables = fun() ->
              Rows = [{ets:info(T, name), ets:info(T, memory), ets:info(T, size), ets:info(T, owner)}
                      || T <- ets:all()],
              Live = [{N, M * Word, S, O} || {N, M, S, O} <- Rows, is_integer(M)],
              lists:sublist(lists:reverse(lists:keysort(2, Live)), TopN)
            end,
            Sample = fun() ->
              Began = erlang:monotonic_time(millisecond),
              At = os:system_time(second),
              %% The node's memory without the recorder's own, which the
              %% scans below make large for a moment.
              {memory, Own} = erlang:process_info(self(), memory),
              Memory0 = maps:from_list(erlang:memory()),
              Memory = Memory0#{total := maps:get(total, Memory0) - Own,
                                processes := maps:get(processes, Memory0) - Own,
                                processes_used := maps:get(processes_used, Memory0) - Own},
              Counts = #{processes => erlang:system_info(process_count),
                         ports => erlang:system_info(port_count),
                         atoms => erlang:system_info(atom_count),
                         run_queue => erlang:statistics(total_run_queue_lengths)},
              ByMemory = Top(catch recon:proc_count(memory, TopN + 1)),
              ByMailbox = Top(catch recon:proc_count(message_queue_len, TopN + 1)),
              Watched = erlang:monotonic_time(millisecond),
              ByReductions = Top(catch recon:proc_window(reductions, TopN + 1, 1000)),
              Window = erlang:monotonic_time(millisecond) - Watched,
              Ets = Tables(),
              %% The time spent working, without the second spent watching.
              Work = erlang:monotonic_time(millisecond) - Began - min(Window, 1000),
              #{at => At, memory => Memory, counts => Counts, work_ms => Work,
                top_memory => lists:sublist(ByMemory, TopN),
                top_mailbox => lists:sublist(ByMailbox, TopN),
                top_reductions => lists:sublist(ByReductions, TopN),
                ets => Ets}
            end,
            Parent ! {Ref, started},
            Started = os:system_time(second),
            T0 = erlang:monotonic_time(millisecond),
            Deadline = T0 + Duration,
            Expires = Deadline + Grace,
            Report = fun(Q, Taken, Failed, Spaced) ->
              #{samples => queue:to_list(Q), started => Started,
                ends => Started + Duration div 1000, interval_ms => Interval,
                keep => Keep, taken => Taken, failed => Failed, spaced_out => Spaced,
                recording => erlang:monotonic_time(millisecond) < Deadline,
                read_at => os:system_time(second),
                expires => Started + (Duration + Grace) div 1000}
            end,
            %% After a sample, it waits at least nine times the sample's work,
            %% so that on a node with very many processes it stays under a
            %% tenth of one scheduler, taking fewer samples.
            Loop = fun L(Q, Kept, Taken, Failed, Spaced, Next) ->
              Now = erlang:monotonic_time(millisecond),
              Wait = case Now >= Deadline of
                true -> max(0, Expires - Now);
                false -> max(0, Next - Now)
              end,
              receive
                {read, From, R, Stop} ->
                  From ! {R, Report(Q, Taken, Failed, Spaced)},
                  case Stop of
                    true -> stopped;
                    false -> L(Q, Kept, Taken, Failed, Spaced, Next)
                  end;
                {read_since, From, R, Since} ->
                  Rep = Report(Q, Taken, Failed, Spaced),
                  New = [S || S <- maps:get(samples, Rep), maps:get(at, S) > Since],
                  From ! {R, Rep#{samples := New}},
                  L(Q, Kept, Taken, Failed, Spaced, Next);
                _ ->
                  L(Q, Kept, Taken, Failed, Spaced, Next)
              after Wait ->
                case erlang:monotonic_time(millisecond) of
                  T when T >= Expires -> expired;
                  T when T >= Deadline -> L(Q, Kept, Taken, Failed, Spaced, Next);
                  _ ->
                    {S, Failed2} = try {Sample(), Failed}
                                   catch C:E -> {#{at => os:system_time(second),
                                                   error => {C, E}}, Failed + 1}
                                   end,
                    %% The scans' lists are garbage now: free them, so the
                    %% recorder holds only its samples between them.
                    erlang:garbage_collect(),
                    Q1 = queue:in(S, Q),
                    {Q2, Kept2} = case Kept >= Keep of
                      true -> {queue:drop(Q1), Kept};
                      false -> {Q1, Kept + 1}
                    end,
                    After = erlang:monotonic_time(millisecond),
                    Work = maps:get(work_ms, S, 0),
                    {Next2, Spaced2} = case After + 9 * Work > Next + Interval of
                      true -> {After + 9 * Work, Spaced + 1};
                      false -> {max(Next + Interval, After), Spaced}
                    end,
                    L(Q2, Kept2, Taken + 1, Failed2, Spaced2, Next2)
                end
              end
            end,
            Loop(queue:new(), 0, 0, 0, 0, T0);
          _ ->
            Parent ! {Ref, already_running}
        end
      end,
      spawn(Recorder),
      receive {Ref, Result} -> Result after 5000 -> timeout end
  end.
  """

  @read ~S"""
  case whereis(Name) of
    undefined -> none;
    W ->
      Ref = make_ref(),
      MRef = erlang:monitor(process, W),
      W ! {read, self(), Ref, Stop},
      receive
        {Ref, R} -> erlang:demonitor(MRef, [flush]), {ok, R};
        {'DOWN', MRef, _, _, _} -> none
      after 5000 -> timeout
      end
  end.
  """

  @read_since ~S"""
  case whereis(Name) of
    undefined -> none;
    W ->
      Ref = make_ref(),
      MRef = erlang:monitor(process, W),
      W ! {read_since, self(), Ref, Since},
      receive
        {Ref, R} -> erlang:demonitor(MRef, [flush]), {ok, R};
        {'DOWN', MRef, _, _, _} -> none
      after 5000 -> timeout
      end
  end.
  """

  @doc """
  Start recording for `duration_ms`, a sample every `interval_ms`, keeping
  the last `keep` samples. Returns `{:ok, :started}`, or `{:ok,
  :already_running}` if a recorder is there (only one at a time).
  """
  def start(duration_ms, interval_ms, keep) do
    bindings = [
      Name: @name,
      Duration: duration_ms,
      Interval: interval_ms,
      Keep: keep,
      Grace: @grace_ms,
      TopN: @top
    ]

    case Checks.remote_eval(@start, bindings) do
      {:ok, result} when result in [:started, :already_running] -> {:ok, result}
      {:ok, :timeout} -> {:error, "the recorder did not start within 5 s"}
      err -> err
    end
  end

  @doc "What the recorder has (and end it, if `stop`), or `:none`."
  def read(stop \\ false) do
    case Checks.remote_eval(@read, Name: @name, Stop: stop) do
      {:ok, {:ok, report}} -> {:ok, report}
      {:ok, :none} -> :none
      {:ok, :timeout} -> {:error, "the recorder did not answer within 5 s"}
      err -> err
    end
  end

  @doc "Like `read/1`, with only the samples taken after `since` (seconds, the node's clock)."
  def read_since(since) do
    case Checks.remote_eval(@read_since, Name: @name, Since: since) do
      {:ok, {:ok, report}} -> {:ok, report}
      {:ok, :none} -> :none
      {:ok, :timeout} -> {:error, "the recorder did not answer within 5 s"}
      err -> err
    end
  end

  @doc "The recorder's state, without its samples."
  def status(report) do
    work = for %{work_ms: ms} <- report.samples, do: ms

    %{
      recording: report.recording,
      started: time(report.started, report.read_at),
      ends: time(report.ends, report.read_at),
      readable_until: time(report.expires, report.read_at),
      interval_s: div(report.interval_ms, 1000),
      samples_kept: length(report.samples),
      keeps_at_most: report.keep
    }
    |> Map.merge(
      if work == [],
        do: %{},
        else: %{
          sample_work_ms: %{average: round(Enum.sum(work) / length(work)), max: Enum.max(work)},
          samples_spaced_out: Map.get(report, :spaced_out, 0),
          sample_cost:
            "each sample reads every process a few times (the work above) and watches CPU " <>
              "for a second; the recorder sleeps between samples, at least nine times as " <>
              "long as a sample's work, so it stays under a tenth of one scheduler"
        }
    )
  end

  # -- History --------------------------------------------------------------------

  @mib 1_048_576

  # What counts as a change worth a sentence, per series: an absolute
  # amount, and a share of where it started.
  @series [
    {[:memory, :total], "Total memory", :bytes, 50 * @mib, 0.25},
    {[:memory, :processes], "Process memory", :bytes, 50 * @mib, 0.25},
    {[:memory, :binary], "Binary memory", :bytes, 50 * @mib, 0.25},
    {[:memory, :ets], "ETS memory", :bytes, 50 * @mib, 0.25},
    {[:counts, :processes], "The number of processes", :count, 1_000, 0.25},
    {[:counts, :ports], "The number of ports", :count, 200, 0.25},
    {[:counts, :atoms], "The number of atoms", :count, 1_000, 0.05},
    {[:counts, :run_queue], "The run queue", :count, 50, 1.0}
  ]

  @mailbox 1_000
  @process_memory 50 * @mib
  @table_memory 50 * @mib

  @doc """
  The conclusions from a report of `read/1`: over its last `minutes`, or
  all it kept. With `raw: true`, the samples too.
  """
  def history(report, opts \\ []) do
    samples =
      report.samples
      |> Enum.reject(&Map.has_key?(&1, :error))
      |> within(report.read_at, opts[:minutes])

    now = report.read_at

    base = %{
      recorder: status(report),
      window: window(samples, now),
      samples: length(samples)
    }

    if length(samples) < 2 do
      Map.put(base, :conclusions, [
        "Too few samples to see a trend yet (#{length(samples)}): the recorder takes one " <>
          "every #{div(report.interval_ms, 1000)} s, and keeps what it took since it started."
      ])
    else
      base
      |> Map.merge(%{
        conclusions:
          Enum.map(problems(samples, now), & &1.text) ++
            busiest(samples) ++ gaps(samples, report) ++ failures(report),
        busiest_process: busiest_field(samples)
      })
      |> then(fn h ->
        if h.conclusions == [],
          do:
            Map.put(h, :conclusions, [
              "Nothing changed much in the window: memory, process, port and atom counts stayed " <>
                "within their thresholds, and no mailbox reached #{count(@mailbox)}."
            ]),
          else: h
      end)
      |> then(fn h -> if opts[:raw], do: Map.put(h, :raw, raw(samples)), else: h end)
    end
  end

  @doc """
  The problems in `samples` (oldest first, two or more): what history
  says, each with a `key` that stays the same while the problem lasts, and
  whether it still is in the latest sample (`ongoing`), which is what
  `wait_for_problem` watches for.
  """
  def problems(samples, now) do
    series_trends(samples, now) ++ processes(samples, now) ++ tables(samples, now)
  end

  defp within(samples, _now, nil), do: samples

  defp within(samples, now, minutes) when is_integer(minutes),
    do: Enum.filter(samples, &(&1.at >= now - minutes * 60))

  defp window([], _now), do: nil

  defp window(samples, now) do
    "#{time(hd(samples).at, now)} to #{time(List.last(samples).at, now)}"
  end

  # The memory categories are part of the total: when the total rose, its
  # sentence says which grew most, and theirs are left out.
  defp series_trends(samples, now) do
    total = trend(hd(@series), samples, now)
    rose? = Enum.any?(total, &(&1.kind == :rise))

    rest =
      for {[group, _], _, _, _, _} = s <- tl(@series),
          not (rose? and group == :memory),
          t <- trend(s, samples, now),
          do: t

    total =
      for t <- total do
        if t.kind == :rise,
          do: %{t | text: t.text <> mostly(samples, t)},
          else: t
      end

    total ++ rest
  end

  # The category that grew most across the total's rise.
  defp mostly(samples, %{from: t1, to: t2}) do
    s1 = Enum.find(samples, &(&1.at == t1))
    s2 = Enum.find(samples, &(&1.at == t2))

    {category, gain} =
      [:processes, :binary, :ets, :code, :atom]
      |> Enum.map(&{&1, (s2.memory[&1] || 0) - (s1.memory[&1] || 0)})
      |> Enum.max_by(&elem(&1, 1))

    name = %{processes: "process", binary: "binary", ets: "ETS", code: "code", atom: "atom"}

    if gain > 0,
      do: " Most of the rise was #{name[category]} memory (+#{amount(gain, :bytes)}).",
      else: ""
  end

  # A series' biggest rise, and its biggest fall, if either is worth saying.
  defp trend({path, label, unit, abs, rel}, samples, now) do
    points = for s <- samples, v = get_in(s, path), is_number(v), do: {s.at, v}

    case points do
      [_, _ | _] ->
        {_, last} = List.last(points)

        up = rise(points, abs, rel)
        down = fall(points, abs, rel)

        # A spike: the fall starts at the rise's peak, whose sentence says
        # where it is now.
        down =
          case {up, down} do
            {{:rise, _, peak}, {:fall, peak, _}} -> nil
            _ -> down
          end

        [up, down]
        |> Enum.reject(&is_nil/1)
        |> Enum.map(fn {kind, {t1, v1}, {t2, v2}} ->
          verb = if kind == :rise, do: "rose", else: "fell"

          after_text =
            cond do
              {t2, v2} == List.last(points) -> ", the latest sample"
              kind == :rise and last >= 0.9 * v2 -> ", and is still there"
              kind == :rise -> "; it is #{amount(last, unit)} now"
              kind == :fall and last <= 1.1 * v2 + 1 -> ", and stayed down"
              true -> "; it is #{amount(last, unit)} now"
            end

          %{
            key: {:series, path, kind},
            kind: kind,
            from: t1,
            to: t2,
            ongoing: if(kind == :rise, do: last >= 0.9 * v2, else: last <= 1.1 * v2 + 1),
            text:
              "#{label} #{verb} from #{amount(v1, unit)} at #{time(t1, now)} to " <>
                "#{amount(v2, unit)} at #{time(t2, now)} (#{span(t2 - t1)})#{after_text}." <>
                peak_holders(kind, path, samples, t2)
          }
        end)

      _ ->
        []
    end
  end

  # The largest rise: the lowest point before the highest that follows it.
  defp rise(points, abs, rel) do
    {_, best} =
      Enum.reduce(points, {nil, nil}, fn {_, v} = p, {low, best} ->
        low = if low == nil or v < elem(low, 1), do: p, else: low
        gain = v - elem(low, 1)

        best =
          if best == nil or gain > elem(best, 0), do: {gain, low, p}, else: best

        {low, best}
      end)

    case best do
      {gain, {_, v1} = from, to} when gain >= abs and gain >= rel * max(v1, 1) ->
        {:rise, from, to}

      _ ->
        nil
    end
  end

  defp fall(points, abs, rel) do
    case rise(Enum.map(points, fn {t, v} -> {t, -v} end), abs, 0) do
      {:rise, {t1, v1}, {t2, v2}} when -v2 <= (1 - rel) * -v1 ->
        {:fall, {t1, -v1}, {t2, -v2}}

      _ ->
        nil
    end
  end

  # For a rise of the total memory: who held most of it at the peak.
  defp peak_holders(:rise, [:memory, :total], samples, t) do
    case Enum.find(samples, &(&1.at == t)) do
      %{top_memory: [{pid, bytes, initial, info} | _], memory: %{total: total}}
      when bytes >= 0.2 * total ->
        " At the peak, #{label(pid, initial, info)} held #{amount(bytes, :bytes)} of it " <>
          "(#{round(100 * bytes / total)}% of the node's memory)."

      _ ->
        ""
    end
  end

  defp peak_holders(_, _, _, _), do: ""

  # Processes whose mailbox reached @mailbox, or whose memory grew by
  # @process_memory, while they were among the top five: one sentence each.
  defp processes(samples, now) do
    first_at = hd(samples).at
    mailboxes = by_identity(samples, :top_mailbox)
    memories = by_identity(samples, :top_memory)

    long =
      for {key, pts} <- mailboxes, Enum.any?(pts, &(&1.value >= @mailbox)), into: %{} do
        {key, pts}
      end

    grown =
      for {key, pts} <- memories,
          low = Enum.min_by(pts, & &1.value),
          peak = pts |> Enum.filter(&(&1.at >= low.at)) |> Enum.max_by(& &1.value),
          peak.value - low.value >= @process_memory,
          into: %{} do
        {key, {low, peak, pts}}
      end

    (Map.keys(long) ++ Map.keys(grown))
    |> Enum.uniq()
    |> Enum.map(fn key ->
      mailbox = long[key] && mailbox_text(long[key], samples, first_at, now)
      memory = grown[key] && memory_text(grown[key], samples, now)
      peak = if long[key], do: Enum.max_by(long[key], & &1.value), else: elem(grown[key], 1)
      size = if long[key], do: peak.value, else: 0
      parts = Enum.reject([mailbox, memory], &is_nil/1)

      # Still a problem in the latest sample: the mailbox still long, or
      # the memory still near its peak.
      ongoing =
        (long[key] && match?(%{value: v} when v >= @mailbox, latest(long[key], samples))) ||
          (grown[key] &&
             match?(%{value: v} when v >= 0.9 * peak.value, latest(elem(grown[key], 2), samples)))

      {size,
       %{
         key: {:process, key},
         ongoing: ongoing == true,
         text:
           String.trim_trailing(who(peak), ",") <>
             ": " <> Enum.join(parts, "; ") <> where(peak) <> "."
       }}
    end)
    |> Enum.sort_by(&(-elem(&1, 0)))
    |> Enum.take(3)
    |> Enum.map(&elem(&1, 1))
  end

  defp mailbox_text(pts, samples, first_at, now) do
    first = Enum.find(pts, &(&1.value >= @mailbox))
    peak = Enum.max_by(pts, & &1.value)

    start =
      if first.at == first_at,
        do: "its mailbox already held #{count(first.value)} messages when recording began",
        else: "its mailbox passed #{count(@mailbox)} at #{time(first.at, now)}"

    start <>
      " and reached #{count(peak.value)} at #{time(peak.at, now)}" <>
      latest_text(latest(pts, samples), peak, :count)
  end

  defp memory_text({low, peak, pts}, samples, now) do
    "its memory went from #{amount(low.value, :bytes)} at #{time(low.at, now)} to " <>
      "#{amount(peak.value, :bytes)} at #{time(peak.at, now)}" <>
      latest_text(latest(pts, samples), peak, :bytes)
  end

  # Tables whose memory grew by @table_memory among the largest.
  defp tables(samples, now) do
    samples
    |> Enum.flat_map(fn s ->
      for {name, bytes, size, owner} <- s.ets, do: {name, s.at, bytes, size, owner}
    end)
    |> Enum.group_by(&elem(&1, 0))
    |> Enum.map(fn {name, pts} ->
      {_, t1, low, s1, _} = Enum.min_by(pts, &elem(&1, 2))

      {_, t2, high, s2, owner} =
        pts |> Enum.filter(&(elem(&1, 1) >= t1)) |> Enum.max_by(&elem(&1, 2))

      last_at = List.last(samples).at

      ongoing =
        Enum.any?(pts, fn {_, at, bytes, _, _} -> at == last_at and bytes >= 0.9 * high end)

      {name, t1, low, s1, t2, high, s2, owner, ongoing}
    end)
    |> Enum.filter(fn {_, _, low, _, _, high, _, _, _} -> high - low >= @table_memory end)
    |> Enum.sort_by(fn {_, _, low, _, _, high, _, _, _} -> low - high end)
    |> Enum.take(3)
    |> Enum.map(fn {name, t1, low, s1, t2, high, s2, owner, ongoing} ->
      %{
        key: {:table, name},
        ongoing: ongoing,
        text:
          "The ETS table #{Format.inspect(name)} (owned by #{Format.inspect(owner)}) grew from " <>
            "#{amount(low, :bytes)} (#{count(s1)} rows) at #{time(t1, now)} to " <>
            "#{amount(high, :bytes)} (#{count(s2)} rows) at #{time(t2, now)}."
      }
    end)
  end

  # The process at the top by reductions in most samples, if one was.
  defp busiest(samples) do
    case busiest_field(samples) do
      %{share_of_samples: share} = b when share >= 0.5 ->
        [
          "#{b.process} was the busiest process in #{round(share * 100)}% of the samples " <>
            "(up to #{count(b.max_reductions_per_s)} reductions a second)."
        ]

      _ ->
        []
    end
  end

  # Fewer samples than this say nothing about which process is usually busiest.
  defp busiest_field(samples) when length(samples) < 4, do: nil

  defp busiest_field(samples) do
    tops =
      for %{top_reductions: [{pid, reds, initial, info} | _]} <- samples,
          do: {key(pid, info), reds, label(pid, initial, info)}

    case tops do
      [] ->
        nil

      _ ->
        {_, group} =
          tops |> Enum.group_by(&elem(&1, 0)) |> Enum.max_by(fn {_, g} -> length(g) end)

        %{
          process: group |> List.last() |> elem(2),
          share_of_samples: Float.round(length(group) / length(samples), 2),
          max_reductions_per_s: group |> Enum.map(&elem(&1, 1)) |> Enum.max()
        }
    end
  end

  # Samples further apart than the interval: the recorder spaced them out to
  # stay cheap, or the node was too busy to take them on time.
  defp gaps(samples, %{spaced_out: spaced} = report) when spaced > 0 do
    work = for %{work_ms: ms} <- samples, do: ms

    [
      "The recorder spaced #{count(spaced)} of its samples out, to stay under a tenth of " <>
        "one scheduler: each took up to #{count(Enum.max(work, fn -> 0 end))} ms of work on " <>
        "this node, against one every #{div(report.interval_ms, 1000)} s asked for."
    ]
  end

  defp gaps(samples, report) do
    interval_s = report.interval_ms / 1000

    gap =
      samples
      |> Enum.chunk_every(2, 1, :discard)
      |> Enum.map(fn [a, b] -> b.at - a.at end)
      |> Enum.max(fn -> 0 end)

    if gap > 3 * interval_s + 2,
      do: [
        "Samples were up to #{span(gap)} apart, against one every #{round(interval_s)} s: " <>
          "the node was too busy to take them on time, which is itself a sign."
      ],
      else: []
  end

  defp failures(%{failed: 0}), do: []

  defp failures(%{failed: n, taken: taken}),
    do: ["#{count(n)} of #{count(taken)} samples failed (recon may be missing on the node)."]

  # Each process's points in a sample list: by registered name, which
  # survives a restart, else by pid.
  defp by_identity(samples, field) do
    samples
    |> Enum.flat_map(fn s ->
      for {pid, value, initial, info} <- Map.get(s, field, []) do
        {key(pid, info), %{at: s.at, value: value, pid: pid, initial: initial, info: info}}
      end
    end)
    |> Enum.group_by(&elem(&1, 0), &elem(&1, 1))
  end

  defp key(_pid, {name, _}) when is_atom(name) and name != [], do: {:name, name}
  defp key(pid, _), do: {:pid, pid}

  # Its point in the latest sample, if it was among the top there.
  defp latest(pts, samples) do
    last_at = List.last(samples).at
    Enum.find(pts, &(&1.at == last_at))
  end

  defp latest_text(nil, _peak, _unit), do: "; it isn't among the top five in the latest sample"
  defp latest_text(latest, peak, _unit) when latest == peak, do: ", the latest sample"

  defp latest_text(latest, _peak, unit),
    do: "; #{amount(latest.value, unit)} in the latest sample"

  defp where(%{info: {_, current}}) when is_tuple(current), do: ". It was in #{mfa(current)}"
  defp where(_), do: ""

  defp who(%{pid: pid, initial: initial, info: info}), do: label(pid, initial, info)

  defp label(pid, _initial, {name, _}) when is_atom(name) and name != [],
    do: "#{Format.inspect(name)} (#{Format.inspect(pid)})"

  defp label(pid, {_, _, _} = initial, _),
    do: "#{Format.inspect(pid)}, started as #{mfa(initial)},"

  defp label(pid, _, _), do: Format.inspect(pid)

  defp raw(samples) do
    for s <- Enum.take(samples, -60) do
      %{
        at: s.at,
        memory_total: s.memory[:total],
        processes: s.counts[:processes],
        top_mailbox: for({pid, v, i, info} <- s.top_mailbox, do: "#{label(pid, i, info)} #{v}"),
        top_memory: for({pid, v, i, info} <- s.top_memory, do: "#{label(pid, i, info)} #{v}")
      }
    end
  end

  # -- Formatting -----------------------------------------------------------------

  defp mfa({m, f, a}) do
    mod = Atom.to_string(m)

    if String.starts_with?(mod, "Elixir."),
      do: "#{Kernel.inspect(m)}.#{f}/#{a}",
      else: "#{mod}:#{f}/#{a}"
  end

  defp mfa(other), do: Format.inspect(other)

  @doc false
  # A time on the node's clock, in UTC, and how long before `now` it was.
  def time(seconds, now) do
    at =
      seconds
      |> DateTime.from_unix!()
      |> DateTime.to_time()
      |> Time.to_string()

    "#{at} UTC (#{ago(now - seconds)})"
  end

  defp ago(s) when s < 0, do: "in #{span(-s)}"
  defp ago(s) when s < 60, do: "#{s} s ago"
  defp ago(s) when s < 3_600, do: "#{div(s, 60)} min ago"
  defp ago(s), do: "#{div(s, 3_600)} h #{div(rem(s, 3_600), 60)} min ago"

  defp span(s) when s < 60, do: "#{s} s"
  defp span(s) when s < 3_600, do: "#{div(s, 60)} min #{rem(s, 60)} s"
  defp span(s), do: "#{div(s, 3_600)} h #{div(rem(s, 3_600), 60)} min"

  defp amount(v, :bytes) when v >= 1024 * @mib, do: "#{Float.round(v / (1024 * @mib), 1)} GB"
  defp amount(v, :bytes), do: "#{round(v / @mib)} MB"
  defp amount(v, :count), do: count(v)

  defp count(n) when is_integer(n) do
    n
    |> Integer.to_string()
    |> String.reverse()
    |> String.replace(~r/(\d{3})(?=\d)/, "\\1,")
    |> String.reverse()
  end

  defp count(n), do: to_string(n)
end
