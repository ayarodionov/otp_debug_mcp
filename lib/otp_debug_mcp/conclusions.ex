defmodule OtpDebugMcp.Conclusions do
  @moduledoc """
  What the checks' results say together. Each check measures one thing; a
  problem usually shows in several: a process that can't keep up is a long
  mailbox in one check, most of the node's memory in another, the callers
  waiting on it in a third. `from/1` reads the results of `Checks.run_all/0`
  and states each problem once, in a sentence or two, with the numbers
  that support it and the checks they came from.

  `report/1` is what `diagnose` returns: the conclusions, the checks that
  aren't ok in full, and only the names of those that are, so that a
  healthy check costs a word instead of a paragraph.

  Everything here works on results alone, with no call to the target: a
  conclusion says only what a check measured.
  """

  @mib 1_048_576

  @doc "The diagnose report: conclusions, the checks that aren't ok, the names of the rest."
  def report(results) do
    {ok, findings} = Enum.split_with(results, &(&1.status == :ok))
    conclusions = from(results)

    %{
      conclusions: conclusions,
      findings: findings,
      ok: Enum.map(ok, & &1.check),
      vitals: vitals(results),
      note: note(conclusions, findings)
    }
  end

  defp note([], []),
    do:
      "No check found a problem. run_check(<name>) returns an ok check's numbers; " <>
        "snapshot (take, wait, diff) shows what grows over time."

  defp note(_, _),
    do:
      "conclusions say what the checks found together; findings are the checks that " <>
        "aren't ok, in full. run_check(<name>) returns an ok check's numbers, and " <>
        "diagnose with verbose: true every check in full."

  @doc "The conclusions drawn from `results`, the most severe first."
  def from(results) do
    checks = Map.new(results, &{&1.check, &1})

    [
      &mailboxes/1,
      &deadlocks/1,
      &chains/1,
      &waited_on/1,
      &crash_loops/1,
      &cpu/1,
      &long_schedules/1,
      &binaries/1,
      &native_memory/1,
      &fragmentation/1,
      &atoms/1,
      &processes/1
    ]
    |> Enum.flat_map(& &1.(checks))
    |> Enum.sort_by(&rank(&1.severity))
  end

  defp rank(:critical), do: 0
  defp rank(_), do: 1

  # A check's findings, unless it failed or wasn't run.
  defp findings(checks, name) do
    case checks[name] do
      %{status: status, findings: findings} when status != :error -> findings
      _ -> nil
    end
  end

  defp conclusion(severity, sentences, from, next) do
    %{
      severity: severity,
      conclusion: sentences |> Enum.filter(&is_binary/1) |> Enum.join(" "),
      from: from,
      next: next
    }
  end

  # -- Mailboxes -----------------------------------------------------------------

  defp mailboxes(checks) do
    total = get_in(findings(checks, :memory_breakdown) || %{}, [:total_bytes])
    waited = findings(checks, :call_chains)[:most_waited_on] || []

    for %{pid: pid} = o <- List.wrap(findings(checks, :message_queues)) |> Enum.take(3) do
      memory = memory_sentence(o[:memory_bytes], total)
      waiters = Enum.find(waited, &(&1[:process] == pid))

      conclusion(
        if(o.queue_len > 100_000, do: :critical, else: :warning),
        [
          trend_sentence(who(o), o),
          where_sentence(o),
          senders_sentence(o),
          memory,
          waiters && "#{count(waiters.waiting_processes)} processes wait on calls to it."
        ],
        [:message_queues] ++
          if(memory, do: [:memory_breakdown], else: []) ++
          if(waiters, do: [:call_chains], else: []),
        "process_info #{pid} for its state and stack; call_latency on it for its time " <>
          "per message" <>
          if(o[:called_from],
            do: "; module_code for the code at #{o.called_from}.",
            else: "."
          )
      )
    end
  end

  defp who(%{pid: pid, info: %{} = info}) do
    case info do
      %{registered_name: name} -> "#{name} (#{pid})"
      %{initial_call: initial} -> "#{pid}, started as #{initial},"
      _ -> pid
    end
  end

  defp who(%{pid: pid}), do: pid

  defp trend_sentence(who, %{exited_during_check: true} = o),
    do: "#{who} had #{count(o.queue_len)} messages in its mailbox and exited during the check."

  defp trend_sentence(who, %{growth_per_s: growth} = o) when growth > 0,
    do:
      "#{who} can't keep up: its mailbox holds #{count(o.queue_len)} messages and grows " <>
        "by #{count(growth)} a second."

  # Nothing taken and nothing arriving: with arrivals, an unchanged length
  # could be a process that keeps pace.
  defp trend_sentence(who, %{growth_per_s: 0, senders: []} = o),
    do:
      "#{who} isn't reading its mailbox: #{count(o.queue_len)} messages wait in it, and it " <>
        "took none during the second sampled."

  defp trend_sentence(who, %{growth_per_s: growth} = o) when growth < 0,
    do:
      "#{who} has a backlog of #{count(o.queue_len)} messages, shrinking by " <>
        "#{count(-growth)} a second: it is catching up."

  defp trend_sentence(who, o),
    do:
      "#{who} has a backlog of #{count(o.queue_len)} messages, neither growing nor " <>
        "shrinking during the second sampled."

  defp where_sentence(%{in: top, called_from: from}), do: "It is in #{top}, called from #{from}."
  defp where_sentence(%{in: top}), do: "It is in #{top}."
  defp where_sentence(_), do: nil

  defp senders_sentence(%{senders: [top | _]} = o) do
    others = (o[:sending_processes] || 1) - 1

    "#{percent(top.share)} of the messages sent to it come from #{sender(top)}, as " <>
      "#{top.sends}, about #{count(approx(top.messages_per_s))} a second" <>
      case others do
        0 -> "."
        1 -> "; one other process sends to it."
        n -> "; #{n} other processes send to it."
      end
  end

  defp senders_sentence(%{senders: [], senders_watched_ms: ms}),
    do: "Nothing was sent to it during the #{ms} ms watched: the messages came earlier."

  defp senders_sentence(%{senders: text}) when is_binary(text),
    do: "Who fills it wasn't measured: the node predates OTP 27's trace sessions."

  defp senders_sentence(_), do: nil

  defp sender(%{name: name, pid: pid}), do: "#{name} (#{pid})"
  defp sender(%{initial_call: initial, pid: pid}), do: "#{pid}, started as #{initial}"
  defp sender(%{pid: pid}), do: pid

  # The process's memory and the node's total are read at different
  # moments, so the share is approximate, and capped.
  defp memory_sentence(bytes, total)
       when is_integer(bytes) and is_integer(total) and total > 0 and bytes >= 0.2 * total,
       do:
         "It holds #{mb(bytes)}, about #{percent(min(bytes / total, 1.0))} of the node's memory."

  defp memory_sentence(bytes, _total) when is_integer(bytes) and bytes >= 100 * @mib,
    do: "It holds #{mb(bytes)}."

  defp memory_sentence(_, _), do: nil

  # -- Calls ---------------------------------------------------------------------

  defp deadlocks(checks) do
    for [_ | _] = cycle <- findings(checks, :call_chains)[:deadlocks] || [] do
      names = Enum.map(cycle, &label/1)
      outside = cycle |> Enum.map(&(&1[:also_waiting_on_it] || 0)) |> Enum.sum()

      conclusion(
        :critical,
        [
          "Deadlock: #{Enum.join(names, " waits on ")} waits on #{hd(names)}, so none can answer.",
          deadlock_end(cycle),
          outside > 0 && "#{count(outside)} more processes wait on them."
        ],
        [:call_chains],
        "module_code on their callbacks, for the calls they make to each other; " <>
          "recent_errors shows the timeouts this has caused."
      )
    end
  end

  defp deadlock_end(cycle) do
    case cycle |> Enum.map(& &1[:timeout]) |> Enum.uniq() do
      [timeout] when timeout in ["infinity", ":infinity"] ->
        "Their calls have no timeout: they wait forever."

      [ms] when is_integer(ms) ->
        "Each call fails after #{count(ms)} ms, its caller crashes or gets an error, " <>
          "and the next requests deadlock again."

      _ ->
        nil
    end
  end

  defp chains(checks) do
    for [_, _ | _] = chain <- findings(checks, :call_chains)[:chains] || [] do
      last = List.last(chain)

      conclusion(
        :warning,
        [
          "#{length(chain) - 1} calls wait on one another, and the last waits on " <>
            "#{label(last)}: #{Enum.map_join(chain, " → ", &label/1)}.",
          busy_sentence(last)
        ],
        [:call_chains],
        "process_info #{last.process}: what it does is what holds up the others."
      )
    end
  end

  # Processes many wait on, when no mailbox conclusion covers them already.
  defp waited_on(checks) do
    covered = for %{pid: pid} <- List.wrap(findings(checks, :message_queues)), do: pid

    for %{waiting_processes: n} = p <- findings(checks, :call_chains)[:most_waited_on] || [],
        n >= 5,
        p[:process] not in covered do
      conclusion(
        :warning,
        ["#{count(n)} processes wait on calls to #{label(p)}.", busy_sentence(p)],
        [:call_chains],
        "process_info #{p.process}; call_latency on it for how long its callers wait, by request."
      )
    end
  end

  defp busy_sentence(%{exited: true}), do: "It has exited."

  defp busy_sentence(%{current_function: function} = p) do
    queued =
      case p[:message_queue_len] do
        n when is_integer(n) and n > 0 -> " with #{count(n)} messages queued"
        _ -> ""
      end

    "It is in #{function}#{queued}."
  end

  defp busy_sentence(_), do: nil

  defp label(%{name: name, process: pid}), do: "#{name} (#{pid})"
  defp label(%{process: pid}), do: pid

  # -- Supervisors ---------------------------------------------------------------

  @recent_s 60
  @reason_chars 300

  defp crash_loops(checks) do
    sups = findings(checks, :supervisor_restarts) || %{}

    looping =
      for s <- sups[:restarted] || [],
          s[:at_limit] || (s[:last_restart_seconds_ago] || @recent_s + 1) <= @recent_s do
        conclusion(
          if(s[:at_limit], do: :critical, else: :warning),
          [
            "A crash loop under the supervisor #{s.supervisor}" <>
              if(s[:application], do: " (application #{s.application})", else: "") <>
              ": #{count(s.restarts_in_window)} restarts in the last #{s.max_seconds} s, " <>
              "the last #{s.last_restart_seconds_ago} s ago.",
            if(s[:at_limit],
              do:
                "It is at its limit of #{s.max_restarts}: one more crash and it gives up, " <>
                  "which stops all its children.",
              else: "Its limit is #{s.max_restarts}, so nothing fails over and the loop goes on."
            ),
            restarting_sentence(s[:restarting_children])
          ],
          [:supervisor_restarts],
          "recent_errors for the crash reports; trace_calls on the crashing function, " <>
            "with exceptions: true, for the arguments it fails on."
        )
      end

    stuck =
      for name <- sups[:unresponsive] || [] do
        conclusion(
          :warning,
          [
            "The supervisor #{name} didn't answer within a second: it is probably blocked " <>
              "starting a child whose init hangs."
          ],
          [:supervisor_restarts],
          "process_info #{name}: its stack shows the child it is starting."
        )
      end

    looping ++ stuck
  end

  defp restarting_sentence([_ | _] = children) do
    "Restarting now: " <>
      Enum.map_join(children, "; ", fn child ->
        case child[:exit_reason] do
          nil -> child.id
          reason -> "#{child.id}, which exited with #{String.slice(reason, 0, @reason_chars)}"
        end
      end) <> "."
  end

  defp restarting_sentence(_), do: nil

  # -- CPU -----------------------------------------------------------------------

  @saturated 0.85

  defp cpu(checks) do
    with %{normal: [_ | _] = normal} = schedulers <- findings(checks, :schedulers),
         usage = Enum.sum(Enum.map(normal, & &1.usage)) / length(normal),
         true <- usage >= @saturated do
      gc = get_in(findings(checks, :scheduler_time) || %{}, [:gc_share_of_work])

      [
        conclusion(
          :warning,
          [
            "The CPU is saturated: the #{length(normal)} schedulers are #{percent(usage)} busy" <>
              case schedulers[:normal_run_queue] do
                n when is_integer(n) and n > 0 -> ", with #{count(n)} processes waiting to run."
                _ -> "."
              end,
            busiest_sentence(findings(checks, :top_reductions)),
            (is_number(gc) and gc >= 0.3) &&
              "Garbage collection is #{percent(gc)} of the schedulers' work."
          ],
          [:schedulers, :top_reductions] ++
            if(is_number(gc) and gc >= 0.3, do: [:scheduler_time], else: []),
          "hot_spots for where the time goes, by function; profile on the busiest process's module."
        )
      ]
    else
      _ -> []
    end
  end

  defp busiest_sentence([%{reductions_per_s: reds} = top | rest]) do
    lead =
      case rest do
        [%{reductions_per_s: next} | _] when next > 0 and reds >= 3 * next ->
          ", #{round(reds / next)} times the next"

        _ ->
          ""
      end

    "The busiest process is #{who(top)} at #{count(reds)} reductions a second#{lead}."
  end

  defp busiest_sentence(_), do: nil

  # Native code that holds a scheduler, and garbage collections that long.
  defp long_schedules(checks) do
    found = findings(checks, :long_schedules) || %{}

    held =
      for %{max_ms: ms} = p <- found[:long_schedules] || [] do
        conclusion(
          if(ms >= 100, do: :critical, else: :warning),
          [
            "#{named(p)} held a scheduler for #{count(ms)} ms without yielding" <>
              case p[:times] do
                n when is_integer(n) and n > 1 ->
                  ", the longest of #{count(n)} times in #{seconds(found[:watched_ms])}" <>
                    " (#{count(p[:total_ms] || ms)} ms in all)."

                _ ->
                  "."
              end,
            "Erlang code yields within a millisecond, so this is native code, a NIF or a " <>
              "BIF, and every process on that scheduler waited for it.",
            p[:scheduled_in] not in [nil, "nil", ":undefined", "undefined"] &&
              "It was in #{p.scheduled_in} when it started."
          ],
          [:long_schedules],
          "module_code on the modules it runs marks which functions are NIFs; " <>
            "trace_calls or profile on those shows which call takes that long."
        )
      end

    gcs =
      for %{ms: ms} = p <- found[:long_gcs] || [] do
        conclusion(
          :warning,
          [
            "A garbage collection of #{named(p)} took #{count(ms)} ms" <>
              case p[:heap_words] do
                words when is_integer(words) -> ", on a heap of #{mb(words * 8)}."
                _ -> "."
              end
          ],
          [:long_schedules],
          "process_info #{p.pid} for what it holds: a long mailbox, or a large state."
        )
      end

    held ++ gcs
  end

  defp named(%{name: name, pid: pid}), do: "#{name} (#{pid})"
  defp named(%{initial_call: initial, pid: pid}), do: "#{pid}, started as #{initial},"
  defp named(%{pid: pid}), do: pid

  defp seconds(ms) when is_integer(ms), do: "#{div(ms, 1000)} s"
  defp seconds(_), do: "the window"

  # -- Memory --------------------------------------------------------------------

  @holder_bytes 50 * @mib
  @released 100_000

  defp binaries(checks) do
    with %{status: status, findings: f} when status not in [:ok, :error] <- checks[:binary_leak] do
      holders =
        for %{binary_bytes: bytes, share_of_binary_memory: share} = h <-
              f[:largest_holders] || [],
            bytes >= @holder_bytes and share >= 0.5 do
          conclusion(
            :warning,
            [
              "#{who(h)} holds #{mb(bytes)} of binaries, #{percent(share)} of the node's " <>
                "binary memory.",
              held_sentence(h[:held_binaries])
            ],
            [:binary_leak],
            "process_info #{h.pid} with include_state for what it keeps; snapshot (take, " <>
              "wait, diff) to see whether it grows."
          )
        end

      rare =
        for %{binaries_freed: freed} = p <- f[:released_by_gc] || [], freed > @released do
          conclusion(
            :warning,
            [
              "#{who(p)} let go of #{count(freed)} binaries when it was garbage-collected: " <>
                "it handles large binaries and rarely collects by itself, so they stay " <>
                "in memory after it is done with them."
            ],
            [:binary_leak],
            "Hibernate it when idle, or collect after large work; process_info #{p.pid} for what it is."
          )
        end

      holders ++ rare
    else
      _ -> []
    end
  end

  defp held_sentence(%{bytes_kept: kept, bytes_pinned: pinned}) when pinned > 4 * kept,
    do:
      "What it keeps is #{mb(kept)} of slices, which pin #{mb(pinned)} of the binaries " <>
        "they were cut from: copying a slice (binary:copy/1) before keeping it frees the rest."

  defp held_sentence(%{bytes_kept: _}),
    do: "It keeps whole binaries, and nothing bounds how many."

  defp held_sentence(_), do: nil

  defp native_memory(checks) do
    with %{status: status, findings: %{outside_vm_bytes: outside} = f}
         when status not in [:ok, :error] <- checks[:native_memory] do
      [
        conclusion(
          :warning,
          [
            "The OS charges the node #{mb(f.os_memory_bytes)}, and the VM's allocators hold " <>
              "#{mb(f.vm_allocated_bytes)} of it: #{mb(outside)} is memory the VM doesn't " <>
              "manage, which NIFs and drivers allocate themselves and erlang:memory() never shows."
          ],
          [:native_memory],
          "native_code for the native libraries loaded; snapshot (take, wait, diff): " <>
            "native memory that grows while the VM's stays flat is a leak in one of them."
        )
      ]
    else
      _ -> []
    end
  end

  defp fragmentation(checks) do
    with %{status: status, findings: %{unused_bytes: unused} = f}
         when status not in [:ok, :error] <- checks[:allocator_fragmentation] do
      worst =
        (f[:allocators] || [])
        |> Enum.reject(&(&1[:allocator] in ["ll_alloc", :ll_alloc]))
        |> Enum.max_by(&(&1[:unused_bytes] || 0), fn -> nil end)

      [
        conclusion(
          severity(status),
          [
            "The VM holds #{mb(f.allocated_bytes)} from the OS and uses " <>
              "#{percent(f.usage)} of it: #{mb(unused)} sits unused in partly empty " <>
              "carriers, which the OS still counts as the node's memory.",
            worst &&
              "Most of it is in #{worst.allocator} (#{mb(worst.unused_bytes)} unused)."
          ],
          [:allocator_fragmentation],
          "run_check allocator_fragmentation for each allocator; the fix is allocator " <>
            "flags (see its interpretation), after finding what caused the spike."
        )
      ]
    else
      _ -> []
    end
  end

  # -- Limits --------------------------------------------------------------------

  defp atoms(checks) do
    with %{status: status, findings: %{growth_per_second: rate} = f} when status != :ok <-
           checks[:atom_table],
         true <- is_number(rate) and rate > 0 do
      [
        conclusion(
          severity(status),
          [
            "Atoms are created at #{count(round(rate))} a second and are never freed" <>
              case f[:seconds_until_full] do
                s when is_number(s) ->
                  ": the atom table is full, and the node dies, in #{duration(s)}."

                _ ->
                  "."
              end
          ],
          [:atom_table],
          "trace_calls on erlang binary_to_atom or list_to_atom for the caller; look for " <>
            "String.to_atom, list_to_atom, or binary_to_term without safe, on input."
        )
      ]
    else
      _ -> []
    end
  end

  defp processes(checks) do
    with %{status: status, findings: %{growth_per_second: rate} = f} when status != :ok <-
           checks[:process_count],
         true <- is_number(rate) and rate > 0 do
      [
        conclusion(
          severity(status),
          [
            "The number of processes grows by #{count(round(rate))} a second " <>
              "(#{count(f.count)} now)" <>
              case f[:seconds_until_limit] do
                s when is_number(s) ->
                  ": the node reaches its limit, and dies, in #{duration(s)}."

                _ ->
                  "."
              end,
            group_sentence(f[:largest_groups])
          ],
          [:process_count],
          "process_info on the group's sample; supervision_tree for a supervisor with " <>
            "far more children than expected."
        )
      ]
    else
      _ -> []
    end
  end

  defp group_sentence([%{processes: n, initial_call: initial, current_function: function} | _]),
    do: "The largest group is #{count(n)} processes started as #{initial}, now in #{function}."

  defp group_sentence(_), do: nil

  defp severity(:critical), do: :critical
  defp severity(_), do: :warning

  # -- Vitals --------------------------------------------------------------------

  # A few numbers from checks that are informational, so a report with
  # every check ok still says what the node is doing.
  defp vitals(results) do
    checks = Map.new(results, &{&1.check, &1})

    %{}
    |> put(:memory, memory_vital(findings(checks, :memory_breakdown)))
    |> put(:processes, get_in(findings(checks, :process_count) || %{}, [:count]))
    |> put(:schedulers_busy, schedulers_vital(findings(checks, :schedulers)))
    |> put(:busiest_process, busiest_vital(findings(checks, :top_reductions)))
  end

  defp memory_vital(%{total_bytes: total, breakdown: [_ | _] = breakdown}) do
    largest = Enum.max_by(breakdown, & &1.bytes)
    "#{mb(total)}, #{round(largest.percent)}% of it #{largest.category}"
  end

  defp memory_vital(_), do: nil

  defp schedulers_vital(%{normal: [_ | _] = normal}),
    do: percent(Enum.sum(Enum.map(normal, & &1.usage)) / length(normal))

  defp schedulers_vital(_), do: nil

  defp busiest_vital([%{reductions_per_s: reds} = top | _]),
    do: "#{who(top)} at #{count(reds)} reductions a second"

  defp busiest_vital(_), do: nil

  defp put(map, _key, nil), do: map
  defp put(map, key, value), do: Map.put(map, key, value)

  # -- Numbers -------------------------------------------------------------------

  defp count(n) when is_integer(n) do
    sign = if n < 0, do: "-", else: ""

    digits =
      n
      |> abs()
      |> Integer.to_string()
      |> String.reverse()
      |> String.replace(~r/(\d{3})(?=\d)/, "\\1,")
      |> String.reverse()

    sign <> digits
  end

  defp count(n), do: to_string(n)

  # To two significant digits, for a rate measured over a short window.
  defp approx(n) when is_integer(n) and n >= 100 do
    unit = Integer.pow(10, length(Integer.digits(n)) - 2)
    round(n / unit) * unit
  end

  defp approx(n), do: n

  defp percent(share), do: "#{round(share * 100)}%"

  defp mb(bytes) when bytes >= 1024 * @mib, do: "#{Float.round(bytes / (1024 * @mib), 1)} GB"
  defp mb(bytes), do: "#{round(bytes / @mib)} MB"

  defp duration(seconds) when seconds < 120, do: "#{round(seconds)} s"
  defp duration(seconds) when seconds < 7_200, do: "#{round(seconds / 60)} minutes"
  defp duration(seconds) when seconds < 172_800, do: "#{round(seconds / 3_600)} hours"
  defp duration(seconds), do: "#{round(seconds / 86_400)} days"
end
