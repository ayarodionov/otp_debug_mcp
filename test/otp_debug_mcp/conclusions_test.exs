defmodule OtpDebugMcp.ConclusionsTest do
  use ExUnit.Case, async: true

  alias OtpDebugMcp.Conclusions

  defp check(name, status, findings),
    do: %{check: name, status: status, findings: findings, interpretation: "what #{name} means"}

  defp offender(fields) do
    Map.merge(
      %{
        pid: "<0.107.0>",
        queue_len: 3_140_479,
        growth_per_s: 60_000,
        memory_bytes: 600 * 1_048_576,
        in: "Process.sleep/1 (lib/process.ex:331)",
        called_from: "Shop.PriceCache.handle_cast/2 (shop.exs:12)",
        info: %{registered_name: "Shop.PriceCache", initial_call: "{Shop.PriceCache, :init, 1}"},
        senders: [
          %{
            pid: "<0.108.0>",
            share: 0.98,
            messages_per_s: 61_000,
            sends: "casts {:update, _, _}",
            initial_call: "{:erlang, :apply, 2}"
          }
        ],
        sending_processes: 2,
        senders_watched_ms: 17
      },
      fields
    )
  end

  test "a mailbox that grows is one conclusion, from three checks" do
    results = [
      check(:message_queues, :critical, [offender(%{})]),
      check(:memory_breakdown, :ok, %{total_bytes: 750 * 1_048_576, breakdown: []}),
      check(:call_chains, :ok, %{
        deadlocks: [],
        chains: [],
        most_waited_on: [%{process: "<0.107.0>", waiting_processes: 12, some_waiters: []}]
      })
    ]

    assert [%{severity: :critical, conclusion: text, from: from, next: next}] =
             Conclusions.from(results)

    assert text =~
             "Shop.PriceCache (<0.107.0>) can't keep up: its mailbox holds 3,140,479 " <>
               "messages and grows by 60,000 a second."

    assert text =~
             "It is in Process.sleep/1 (lib/process.ex:331), called from " <>
               "Shop.PriceCache.handle_cast/2 (shop.exs:12)."

    assert text =~
             "98% of the messages sent to it come from <0.108.0>, started as " <>
               "{:erlang, :apply, 2}, as casts {:update, _, _}; " <>
               "one other process sends to it."

    assert text =~ "It holds 600 MB, about 80% of the node's memory."
    assert text =~ "12 processes wait on calls to it."
    assert from == [:message_queues, :memory_breakdown, :call_chains]
    assert next =~ "module_code for the code at Shop.PriceCache.handle_cast/2"
  end

  test "a mailbox says only what was measured" do
    quiet =
      offender(%{queue_len: 5_000, growth_per_s: 0, senders: []})
      |> Map.drop([:called_from, :memory_bytes, :sending_processes])

    assert [%{severity: :warning, conclusion: text, from: [:message_queues]}] =
             Conclusions.from([check(:message_queues, :warning, [quiet])])

    assert text =~ "isn't reading its mailbox: 5,000 messages wait in it"
    assert text =~ "It is in Process.sleep/1 (lib/process.ex:331)."
    assert text =~ "Nothing was sent to it during the 17 ms watched"
    refute text =~ "memory"

    old = offender(%{senders: "not measured: this node predates OTP 27's trace sessions."})
    assert [%{conclusion: text}] = Conclusions.from([check(:message_queues, :critical, [old])])
    assert text =~ "Who fills it wasn't measured"

    draining = offender(%{growth_per_s: -300, senders: []})

    assert [%{conclusion: text}] =
             Conclusions.from([check(:message_queues, :critical, [draining])])

    assert text =~ "shrinking by 300 a second"
  end

  test "deadlocks, chains and processes many wait on" do
    a = %{process: "<0.1.0>", name: ":orders", waits_on: "a call to :stock", timeout: 5000}
    b = %{process: "<0.2.0>", name: ":stock", waits_on: "a call to :orders", timeout: 5000}
    b = Map.put(b, :also_waiting_on_it, 4)
    last = %{process: "<0.5.0>", current_function: "{:timer, :sleep, 1}", message_queue_len: 7}

    busy = %{
      process: "<0.9.0>",
      name: ":registry",
      current_function: "{:gen_server, :loop, 5}",
      message_queue_len: 0,
      waiting_processes: 8
    }

    results = [
      check(:call_chains, :critical, %{
        deadlocks: [[a, b]],
        chains: [[%{process: "<0.3.0>"}, %{process: "<0.4.0>"}, last]],
        most_waited_on: [busy, %{process: "<0.8.0>", waiting_processes: 2}]
      })
    ]

    assert [deadlock, chain, waited] = Conclusions.from(results)

    assert deadlock.severity == :critical

    assert deadlock.conclusion ==
             "Deadlock: :orders (<0.1.0>) waits on :stock (<0.2.0>) waits on :orders (<0.1.0>), " <>
               "so none can answer. Each call fails after 5,000 ms, its caller crashes or " <>
               "gets an error, and the next requests deadlock again. 4 more processes wait on them."

    assert chain.conclusion =~ "<0.3.0> → <0.4.0> → <0.5.0>"
    assert chain.conclusion =~ "It is in {:timer, :sleep, 1} with 7 messages queued."

    assert waited.conclusion ==
             "8 processes wait on calls to :registry (<0.9.0>). It is in {:gen_server, :loop, 5}."
  end

  test "a crash loop, and whether the supervisor is about to give up" do
    sup = %{
      supervisor: "Shop.Supervisor",
      application: :shop,
      max_restarts: 3,
      max_seconds: 5,
      restarts_in_window: 3,
      last_restart_seconds_ago: 1,
      at_limit: true,
      restarting_children: [%{id: "Shop.Worker", exit_reason: "{badarg,[{shop,parse,1}]}"}]
    }

    old = %{sup | supervisor: "Old.Sup", at_limit: false, last_restart_seconds_ago: 900}

    results = [
      check(:supervisor_restarts, :critical, %{
        restarted: [sup, old],
        unresponsive: [":stuck_sup"]
      })
    ]

    assert [loop, stuck] = Conclusions.from(results)
    assert loop.severity == :critical

    assert loop.conclusion =~
             "A crash loop under the supervisor Shop.Supervisor (application shop)"

    assert loop.conclusion =~ "one more crash and it gives up"
    assert loop.conclusion =~ "Shop.Worker, which exited with {badarg,[{shop,parse,1}]}"
    assert stuck.conclusion =~ ":stuck_sup didn't answer"
  end

  test "CPU saturation names the busiest process, and garbage collection if it's much" do
    busy = for i <- 1..4, do: %{scheduler: i, usage: 0.97}

    top = [
      %{pid: "<0.50.0>", reductions_per_s: 9_000_000, info: %{registered_name: ":cruncher"}},
      %{pid: "<0.51.0>", reductions_per_s: 1_000_000, info: %{}}
    ]

    results = [
      check(:schedulers, :warning, %{normal: busy, normal_run_queue: 30}),
      check(:top_reductions, :ok, top),
      check(:scheduler_time, :ok, %{gc_share_of_work: 0.4})
    ]

    assert [%{conclusion: text, from: [:schedulers, :top_reductions, :scheduler_time]}] =
             Conclusions.from(results)

    assert text =~ "the 4 schedulers are 97% busy, with 30 processes waiting to run."
    assert text =~ ":cruncher (<0.50.0>) at 9,000,000 reductions a second, 9 times the next."
    assert text =~ "Garbage collection is 40% of the schedulers' work."

    idle = [check(:schedulers, :ok, %{normal: [%{scheduler: 1, usage: 0.1}]}) | tl(results)]
    assert Conclusions.from(idle) == []
  end

  test "native code holding a scheduler, and a long garbage collection" do
    results = [
      check(:long_schedules, :critical, %{
        watched_ms: 2000,
        long_schedules: [
          %{
            pid: "<0.70.0>",
            name: ":thumbnailer",
            times: 4,
            max_ms: 180,
            total_ms: 610,
            scheduled_in: "{Thumbs, :resize, 2}"
          }
        ],
        long_gcs: [%{pid: "<0.71.0>", ms: 90, heap_words: 131_072_000}],
        busy_ports: []
      })
    ]

    assert [held, gc] = Conclusions.from(results)
    assert held.severity == :critical

    assert held.conclusion =~
             ":thumbnailer (<0.70.0>) held a scheduler for 180 ms without yielding, the " <>
               "longest of 4 times in 2 s (610 ms in all)."

    assert held.conclusion =~ "a NIF or a BIF"
    assert held.conclusion =~ "It was in {Thumbs, :resize, 2} when it started."
    assert gc.conclusion == "A garbage collection of <0.71.0> took 90 ms, on a heap of 1000 MB."
  end

  test "memory: binaries held or left uncollected, native memory, fragmentation" do
    mib = 1_048_576

    results = [
      check(:binary_leak, :warning, %{
        binary_memory_bytes: 400 * mib,
        largest_holders: [
          %{
            pid: "<0.80.0>",
            binary_bytes: 380 * mib,
            share_of_binary_memory: 0.95,
            info: %{registered_name: ":slice_keeper"},
            held_binaries: %{sampled: 2000, bytes_kept: 2 * mib, bytes_pinned: 380 * mib}
          },
          %{pid: "<0.81.0>", binary_bytes: mib, share_of_binary_memory: 0.0, info: %{}}
        ],
        released_by_gc: [
          %{pid: "<0.82.0>", binaries_freed: 250_000, info: %{registered_name: ":uploader"}},
          %{pid: "<0.83.0>", binaries_freed: 12, info: %{}}
        ]
      }),
      check(:native_memory, :warning, %{
        os_memory_bytes: 3_000 * mib,
        vm_allocated_bytes: 900 * mib,
        outside_vm_bytes: 2_100 * mib
      }),
      check(:allocator_fragmentation, :critical, %{
        allocated_bytes: 6_000 * mib,
        used_bytes: 1_800 * mib,
        unused_bytes: 4_200 * mib,
        usage: 0.3,
        allocators: [
          %{allocator: "ll_alloc", unused_bytes: 5_000 * mib},
          %{allocator: "binary_alloc", unused_bytes: 3_900 * mib}
        ]
      })
    ]

    assert [fragmented, holder, rare, native] = Conclusions.from(results)

    assert fragmented.severity == :critical

    assert fragmented.conclusion =~
             "holds 5.9 GB from the OS and uses 30% of it: 4.1 GB sits unused"

    assert fragmented.conclusion =~ "Most of it is in binary_alloc (3.8 GB unused)."

    assert holder.conclusion =~
             ":slice_keeper (<0.80.0>) holds 380 MB of binaries, 95% of the node's binary memory."

    assert holder.conclusion =~ "2 MB of slices, which pin 380 MB"
    assert rare.conclusion =~ ":uploader (<0.82.0>) let go of 250,000 binaries"
    assert native.conclusion =~ "charges the node 2.9 GB"
    assert native.conclusion =~ "2.1 GB is memory the VM doesn't manage"

    # An ok check says nothing, whatever it measured.
    assert Conclusions.from(Enum.map(results, &%{&1 | status: :ok})) == []
  end

  test "leaks of atoms and processes say when the node dies" do
    results = [
      check(:atom_table, :critical, %{growth_per_second: 500.0, seconds_until_full: 1_800}),
      check(:process_count, :warning, %{
        count: 40_000,
        growth_per_second: 250.0,
        seconds_until_limit: 4_000,
        largest_groups: [
          %{
            processes: 39_000,
            initial_call: "{Task, :start, 1}",
            current_function: "{:timer, :sleep, 1}"
          }
        ]
      })
    ]

    assert [atoms, processes] = Conclusions.from(results)
    assert atoms.conclusion =~ "created at 500 a second"
    assert atoms.conclusion =~ "in 30 minutes"
    assert processes.conclusion =~ "grows by 250 a second (40,000 now)"
    assert processes.conclusion =~ "39,000 processes started as {Task, :start, 1}"
  end

  test "the report keeps checks that aren't ok in full, and only names the rest" do
    results = [
      check(:message_queues, :critical, [offender(%{})]),
      check(:logs, :warning, %{files: []}),
      check(:memory_breakdown, :ok, %{
        total_bytes: 750 * 1_048_576,
        breakdown: [%{category: :processes, bytes: 600 * 1_048_576, percent: 80.0}]
      }),
      check(:ets_tables, :ok, [%{name: ":big", rows: 10}]),
      check(:ports, :error, [])
    ]

    report = Conclusions.report(results)

    assert [%{severity: :critical}] = report.conclusions
    assert Enum.map(report.findings, & &1.check) == [:message_queues, :logs, :ports]
    assert Enum.all?(report.findings, &(&1.interpretation =~ "what"))
    assert report.ok == [:memory_breakdown, :ets_tables]
    assert report.vitals == %{memory: "750 MB, 80% of it processes"}
    assert report.note =~ "verbose: true"

    # The ok checks' data and interpretations are what the report leaves out.
    refute JSON.encode!(report) =~ ":big"
  end

  test "a healthy node's report is a few lines" do
    results = [
      check(:message_queues, :ok, []),
      check(:call_chains, :ok, %{deadlocks: [], chains: [], most_waited_on: []}),
      check(:process_count, :ok, %{count: 61, growth_per_second: 0.0}),
      check(:schedulers, :ok, %{
        normal: [%{scheduler: 1, usage: 0.03}, %{scheduler: 2, usage: 0.01}]
      })
    ]

    assert %{conclusions: [], findings: [], note: note, vitals: vitals} =
             Conclusions.report(results)

    assert note =~ "No check found a problem"
    assert vitals == %{processes: 61, schedulers_busy: "2%"}
  end
end
