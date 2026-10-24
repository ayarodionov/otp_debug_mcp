defmodule OtpDebugMcp.CrashDump do
  @moduledoc """
  Why a node died, from its erl_crash.dump.

  A crash dump is text: sections that start with `=tag:id`, then
  `Key: value` lines. It's read in one pass, in chunks, so a dump of
  gigabytes takes memory for what's kept, not for the file: the header
  (with the slogan, the VM's last words), memory, the schedulers and the
  process each ran, every process's summary (only the biggest are kept),
  ports, ETS tables, atoms and loaded code. All the processes come before
  their stacks and heaps, so by the stacks it's known which processes
  matter, and only their stacks are kept, and the heap of the one with the
  biggest mailbox, from which its first messages are decoded.

  The format is OTP's (erts's crash dump writer; observer's crashdump_viewer
  reads it too, and its heap-term decoder is what `decode/3` follows).
  """

  alias OtpDebugMcp.Format.Printed

  @chunk 4 * 1024 * 1024
  @top 10
  @keep_procs 5_000
  # Heap lines kept: for decoding the biggest mailbox, and for the other
  # selected processes' dictionaries (what proc_lib processes run).
  @heap_lines 500_000
  @heap_lines_other 20_000
  # Literals (constant terms in code, such as a map's keys) that heap
  # terms point to.
  @literal_lines 200_000
  @sample_messages 5

  defstruct version: nil,
            header: %{},
            section: nil,
            schedulers: %{},
            memory: %{},
            atom_table: %{},
            procs: [],
            kept_procs: 0,
            proc_count: 0,
            states: %{},
            spawned_as: %{},
            ports: %{},
            port_count: 0,
            ets: [],
            kept_ets: 0,
            ets_count: 0,
            timers: 0,
            node: nil,
            modules: 0,
            elixir: false,
            code_bytes: nil,
            selected: nil,
            sample: nil,
            focus: nil,
            stacks: %{},
            messages: %{},
            heap: %{},
            heap_lines: %{},
            literals: %{},
            dicts: %{},
            current: %{},
            complete: false

  @doc """
  Analyze the dump at `path`. Options: `process:` a pid as the dump prints
  it, e.g. "<0.88.0>", to include that process in full.
  """
  def analyze(path, opts \\ []) do
    with {:ok, fd} <- open(path) do
      try do
        case IO.binread(fd, 64) do
          "=erl_crash_dump:" <> _ = start ->
            state = scan(fd, %__MODULE__{focus: opts[:process]}, start)
            {:ok, report(state, path, opts[:process])}

          :eof ->
            {:error,
             "#{path} is empty: the node is still writing it (a dump is done when the node " <>
               "has exited), or was killed before it could"}

          _ ->
            {:error, "#{path} isn't an Erlang crash dump: it doesn't start with =erl_crash_dump"}
        end
      after
        File.close(fd)
      end
    end
  end

  defp open(path) do
    case File.open(path, [:read, :binary, :raw]) do
      {:ok, fd} ->
        {:ok, fd}

      {:error, :enoent} ->
        {:error,
         "no file #{path} on the machine running this server. A dump written in a container " <>
           "or pod must be copied here first (docker cp, kubectl cp)"}

      {:error, reason} ->
        {:error, "can't read #{path}: #{:file.format_error(reason)}"}
    end
  end

  ## Reading

  defp scan(fd, state, rest) do
    case IO.binread(fd, @chunk) do
      :eof ->
        if rest == "", do: state, else: line(rest, state)

      {:error, reason} ->
        raise "reading the dump failed: #{inspect(reason)}"

      data ->
        {state, rest} = lines(rest <> data, 0, state)
        scan(fd, state, rest)
    end
  end

  # The lines of `buffer` from `pos`, which starts one; returns the last,
  # unfinished one. Lines that are kept are copied, so they don't keep the
  # whole chunk in memory.
  defp lines(buffer, pos, state) do
    size = byte_size(buffer)

    cond do
      pos == size ->
        {state, ""}

      state.section == nil and :binary.at(buffer, pos) != ?= ->
        # A section of no interest: on to the next one.
        case :binary.match(buffer, "\n=", scope: {pos, size - pos}) do
          {at, _} -> lines(buffer, at + 1, state)
          :nomatch -> {state, unfinished(buffer, pos)}
        end

      true ->
        case :binary.match(buffer, "\n", scope: {pos, size - pos}) do
          {at, _} ->
            state = line(:binary.copy(binary_part(buffer, pos, at - pos)), state)
            lines(buffer, at + 1, state)

          :nomatch ->
            {state, binary_part(buffer, pos, size - pos)}
        end
    end
  end

  # What's left after the last line break, which may begin the next section.
  defp unfinished(buffer, pos), do: after_last_newline(buffer, byte_size(buffer) - 1, pos)

  defp after_last_newline(buffer, i, pos) when i < pos,
    do: binary_part(buffer, pos, byte_size(buffer) - pos)

  defp after_last_newline(buffer, i, pos) do
    case :binary.at(buffer, i) do
      ?\n -> binary_part(buffer, i + 1, byte_size(buffer) - i - 1)
      _ -> after_last_newline(buffer, i - 1, pos)
    end
  end

  defp line("=" <> header, state) do
    {tag, id} =
      case :binary.split(header, ":") do
        [tag, id] -> {tag, id}
        [tag] -> {tag, nil}
      end

    enter(tag, id, state)
  end

  defp line(text, %{section: section} = state), do: body(section, text, state)

  defp enter("erl_crash_dump", version, state),
    do: %{state | version: version, section: :header}

  defp enter("end", _, state), do: %{state | complete: true, section: nil}
  defp enter("memory", _, state), do: %{state | section: :memory}
  defp enter("literals", _, state), do: %{state | section: :literals}
  defp enter("index_table", "atom_tab", state), do: %{state | section: :atom_tab}
  defp enter("proc", pid, state), do: new_proc(state, pid)

  defp enter("port", port, state),
    do: %{state | section: {:port, port}, port_count: state.port_count + 1}

  defp enter("ets", owner, state) do
    state = prune_ets(state)

    %{
      state
      | section: :ets,
        ets: [%{owner: owner} | state.ets],
        kept_ets: state.kept_ets + 1,
        ets_count: state.ets_count + 1
    }
  end

  defp enter("timer", _, state), do: %{state | section: nil, timers: state.timers + 1}
  defp enter("node", name, state), do: %{state | section: nil, node: String.trim(name, "'")}
  defp enter("no_distribution", _, state), do: %{state | section: nil, node: "not distributed"}
  defp enter("loaded_modules", _, state), do: %{state | section: :loaded_modules}

  defp enter("mod", name, state) do
    %{
      state
      | section: nil,
        modules: state.modules + 1,
        elixir: state.elixir or name in ["Elixir.Kernel", "'Elixir.Kernel'"]
    }
  end

  defp enter(tag, pid, state)
       when tag in ["proc_dictionary", "proc_stack", "proc_messages", "proc_heap"] do
    state = select(state)
    selected? = MapSet.member?(state.selected, pid)

    cond do
      tag == "proc_dictionary" and selected? ->
        %{state | section: {:dict, pid}, dicts: Map.put(state.dicts, pid, [])}

      tag == "proc_stack" and selected? ->
        %{state | section: {:stack, pid}, stacks: Map.put(state.stacks, pid, [])}

      tag == "proc_messages" and pid in state.sample ->
        %{state | section: {:messages, pid}, messages: Map.put(state.messages, pid, [])}

      tag == "proc_heap" and selected? ->
        cap = if pid in state.sample, do: @heap_lines, else: @heap_lines_other
        %{state | section: {:heap, pid, cap}}

      true ->
        %{state | section: nil}
    end
  end

  defp enter(tag, id, state) do
    if String.ends_with?(tag, "scheduler"),
      do: %{state | section: {:scheduler, "#{scheduler_kind(tag)}#{id}"}},
      else: %{state | section: nil}
  end

  defp scheduler_kind("scheduler"), do: ""
  defp scheduler_kind(tag), do: String.replace_suffix(tag, "scheduler", "")

  defp body(nil, _text, state), do: state

  defp body(:header, text, state) do
    case kv(text) do
      {key, value} -> put_in(state.header[key], value)
      nil when map_size(state.header) == 0 -> put_in(state.header["Written"], text)
      # A slogan with line breaks.
      nil -> update_in(state.header["Slogan"], &((&1 || "") <> "\n" <> text))
    end
  end

  defp body(:memory, text, state) do
    case kv(text) do
      {key, value} -> put_in(state.memory[key], int(value))
      nil -> state
    end
  end

  defp body(:atom_tab, text, state) do
    case kv(text) do
      {key, value} -> put_in(state.atom_table[key], int(value))
      nil -> state
    end
  end

  defp body(:loaded_modules, "Current code: " <> bytes, state),
    do: %{state | code_bytes: int(bytes)}

  defp body(:loaded_modules, _text, state), do: state

  defp body({:scheduler, id}, text, state) do
    sched = Map.get(state.schedulers, id, %{stack: []})

    sched =
      case {kv(text), text} do
        {_, "0x" <> _} ->
          case function_in(text) do
            nil -> sched
            frame -> Map.update!(sched, :stack, &[frame | &1])
          end

        {{key, value}, _} ->
          Map.put(sched, key, value)

        _ ->
          sched
      end

    put_in(state.schedulers[id], sched)
  end

  defp body(:proc, text, %{procs: [proc | procs]} = state) do
    case kv(text) do
      {"State", value} ->
        %{
          state
          | procs: [Map.put(proc, :state, value) | procs],
            states: bump(state.states, value)
        }

      {"Spawned as", value} ->
        %{
          state
          | procs: [Map.put(proc, :spawned_as, value) | procs],
            spawned_as: bump(state.spawned_as, value)
        }

      {key, value} ->
        case proc_field(key, value) do
          nil ->
            state

          {:current, f} ->
            %{
              state
              | procs: [Map.put(proc, :current, f) | procs],
                current: bump(state.current, f)
            }

          {k, v} ->
            %{state | procs: [Map.put(proc, k, v) | procs]}
        end

      nil ->
        state
    end
  end

  defp body({:port, _}, "Port controls " <> what, state) do
    type =
      case :binary.split(what, ": ") do
        ["linked-in driver", name] -> name
        ["external process", command] -> "external: #{command}"
        [kind, name] -> "#{kind}: #{name}"
        _ -> what
      end

    %{state | ports: bump(state.ports, type)}
  end

  defp body({:port, _}, _text, state), do: state

  defp body(:ets, text, %{ets: [table | tables]} = state) do
    case kv(text) do
      {key, value} when key in ["Table", "Name", "Type"] ->
        %{state | ets: [Map.put(table, String.downcase(key), value) | tables]}

      {key, value} when key in ["Objects", "Words"] ->
        %{state | ets: [Map.put(table, String.downcase(key), int(value)) | tables]}

      _ ->
        state
    end
  end

  defp body({:stack, pid}, text, state) do
    case function_in(text) do
      nil -> state
      frame -> update_in(state.stacks[pid], &[frame | &1])
    end
  end

  # A message: its term, then its seq_trace token.
  defp body({:messages, pid}, text, state) do
    if length(state.messages[pid]) < @sample_messages,
      do: update_in(state.messages[pid], &[text | &1]),
      else: state
  end

  defp body(:literals, text, state) do
    case :binary.split(text, ":") do
      [addr, term] when map_size(state.literals) < @literal_lines ->
        %{state | literals: Map.put(state.literals, addr, term)}

      [_, _] ->
        %{state | section: nil}

      _ ->
        state
    end
  end

  defp body({:dict, pid}, text, state),
    do: update_in(state.dicts[pid], &[text | &1])

  defp body({:heap, pid, cap}, text, state) do
    kept = Map.get(state.heap_lines, pid, 0)

    case :binary.split(text, ":") do
      [addr, term] when kept < cap ->
        heap = Map.update(state.heap, pid, %{addr => term}, &Map.put(&1, addr, term))
        %{state | heap: heap, heap_lines: Map.put(state.heap_lines, pid, kept + 1)}

      # Enough: the rest of the heap is skipped.
      [_, _] ->
        %{state | section: nil}

      _ ->
        state
    end
  end

  defp body(_section, _text, state), do: state

  defp kv(text) do
    case :binary.split(text, ": ") do
      [key, value] -> {key, value}
      _ -> nil
    end
  end

  defp proc_field("Name", v), do: {:name, v}
  defp proc_field("Spawned by", v), do: {:spawned_by, v}
  defp proc_field("Message queue length", v), do: {:message_queue_len, int(v)}
  defp proc_field("Memory", v), do: {:memory, int(v)}
  defp proc_field("Reductions", v), do: {:reductions, int(v)}
  defp proc_field("Stack+heap", v), do: {:heap_words, int(v)}
  defp proc_field("Program counter", v), do: {:current, function_in(v)}
  defp proc_field("Current call", v), do: {:current_call, v}
  defp proc_field("Link list", v), do: {:links, v}
  defp proc_field(_, _), do: nil

  # "0x...:SReturn addr 0x3614664 (erl_eval:do_apply/7 + 476)" -> "erl_eval:do_apply/7"
  defp function_in(text) do
    case Regex.run(~r/\(([^()]+\/\d+) \+ \d+\)/, text, capture: :all_but_first) do
      [function] -> function
      nil -> nil
    end
  end

  defp int(text) do
    case Integer.parse(String.trim(text)) do
      {n, _} -> n
      :error -> nil
    end
  end

  defp bump(map, key), do: Map.update(map, key, 1, &(&1 + 1))

  ## Keeping what matters

  defp new_proc(state, pid) do
    state = if state.kept_procs > @keep_procs, do: prune_procs(state), else: state

    %{
      state
      | section: :proc,
        procs: [%{pid: pid} | state.procs],
        kept_procs: state.kept_procs + 1,
        proc_count: state.proc_count + 1
    }
  end

  # The processes worth showing: the biggest, the longest mailboxes, the
  # ones the schedulers ran, and the one asked for.
  defp prune_procs(state) do
    keep = keep_set(state.procs, state)
    procs = Enum.filter(state.procs, &MapSet.member?(keep, &1.pid))
    %{state | procs: procs, kept_procs: length(procs)}
  end

  defp keep_set(procs, state) do
    by(procs, :memory)
    |> Enum.concat(by(procs, :message_queue_len))
    |> Enum.concat(Enum.filter(procs, &active?/1))
    |> Enum.map(& &1.pid)
    |> Enum.concat(special_pids(state))
    |> MapSet.new()
  end

  # On a scheduler when the node died: running, or collecting its garbage.
  defp active?(proc), do: proc[:state] in ["Running", "Garbing"]

  defp by(procs, key) do
    procs
    |> Enum.filter(&is_integer(&1[key]))
    |> Enum.sort_by(&(-&1[key]))
    |> Enum.take(@top)
  end

  defp special_pids(state) do
    running =
      for {_id, %{"Current Process" => pid}} <- state.schedulers, pid != "", do: pid

    if state.focus, do: [state.focus | running], else: running
  end

  defp prune_ets(%{kept_ets: kept, ets: ets} = state) when kept > 1_000,
    do: %{
      state
      | ets: ets |> Enum.sort_by(&(-(&1["words"] || 0))) |> Enum.take(@top),
        kept_ets: @top
    }

  defp prune_ets(state), do: state

  defp select(%{selected: nil} = state) do
    state = prune_procs(state)

    sample =
      case Enum.max_by(state.procs, &(&1[:message_queue_len] || 0), fn -> nil end) do
        %{message_queue_len: n, pid: pid} when n > 0 -> [pid]
        _ -> []
      end

    %{
      state
      | selected: keep_set(state.procs, state),
        sample: Enum.uniq(sample ++ List.wrap(state.focus))
    }
  end

  defp select(state), do: state

  ## The report

  defp report(state, path, focus) do
    syntax = if state.elixir, do: :elixir, else: :erlang
    words = if state.header["System version"] =~ "[64-bit]", do: 8, else: 4
    total = state.memory["total"]
    procs = Enum.map(state.procs, &describe_proc(&1, state, total))
    calling = calling(state, total)

    %{
      file: path,
      complete:
        if(state.complete,
          do: true,
          else:
            "no: the dump ends early. The node is still writing it, was killed while " <>
              "writing it (by a supervisor such as heart or Kubernetes, or ERL_CRASH_DUMP_SECONDS), " <>
              "or ERL_CRASH_DUMP_BYTES cut it short; what's here is still right"
        ),
      written: state.header["Written"],
      node: state.node,
      system_version: state.header["System version"],
      slogan: state.header["Slogan"],
      cause: cause(state.header["Slogan"] || "", state),
      memory_mb: Map.new(state.memory, fn {k, v} -> {k, mb(v)} end),
      running_when_it_died: calling,
      processes: %{
        count: state.proc_count,
        by_state: state.states,
        most_spawned_as: top_counts(state.spawned_as, 5),
        most_common_current_function: top_counts(state.current, 5),
        top_memory: top_memory(procs),
        top_message_queues:
          procs
          |> Enum.filter(&((&1[:message_queue_len] || 0) > 0))
          |> Enum.sort_by(&(-&1.message_queue_len))
          |> Enum.take(@top)
      },
      ports: %{count: state.port_count, by_type: top_counts(state.ports, 10)},
      ets: %{
        count: state.ets_count,
        largest:
          state.ets
          |> Enum.sort_by(&(-(&1["words"] || 0)))
          |> Enum.take(5)
          |> Enum.map(&describe_ets(&1, words))
      },
      atoms: atoms(state),
      loaded_modules: state.modules,
      timers: state.timers,
      taints: state.header["Taints"],
      findings: findings(state, procs, total, words),
      interpretation: interpretation()
    }
    |> Map.merge(mailbox_sample(state, syntax))
    |> Map.merge(focus(state, focus, total, syntax))
  end

  # The biggest processes: those with at least 1% of the memory, and at
  # least three.
  defp top_memory(procs) do
    sorted = procs |> Enum.filter(& &1[:memory_mb]) |> Enum.sort_by(&(-&1.memory_mb))
    {first, rest} = Enum.split(sorted, 3)
    Enum.take(first ++ Enum.filter(rest, &((&1[:share_of_memory] || 0) >= 1)), @top)
  end

  defp describe_proc(proc, state, total) do
    %{pid: proc.pid}
    |> put(:name, proc[:name])
    |> put(:spawned_as, proc[:spawned_as])
    |> put(:initial_call, initial_call(state, proc.pid))
    |> put(:state, proc[:state])
    |> put(:memory_mb, proc[:memory] && mb(proc[:memory]))
    |> put(:share_of_memory, proc[:memory] && total && percent(proc[:memory], total))
    |> put(:message_queue_len, proc[:message_queue_len])
    |> put(:reductions, proc[:reductions])
    |> put(:current_function, proc[:current])
    |> put(:stack, stack(state.stacks[proc.pid]))
  end

  # What a proc_lib process (a gen_server, a Task...) was started to run,
  # from its dictionary, if its heap line is among those kept.
  defp initial_call(state, pid) do
    ctx = %{
      heap: Map.get(state.heap, pid, %{}),
      literals: state.literals,
      base64: base64?(state.version)
    }

    Enum.find_value(state.dicts[pid] || [], fn line ->
      case decode(line, ctx, {4, 20}) do
        {{:"$initial_call", {m, f, a}}, _, _} when is_atom(m) and is_atom(f) and is_integer(a) ->
          "#{inspect_atom(m)}:#{inspect_atom(f)}/#{a}"

        _ ->
          nil
      end
    end)
  end

  defp inspect_atom(atom), do: :io_lib.write_atom(atom) |> IO.chardata_to_string()

  defp stack(nil), do: nil

  defp stack(frames) do
    frames
    |> Enum.reverse()
    |> Enum.dedup()
    |> Enum.reject(&(&1 == "<terminate process normally>"))
    |> Enum.take(15)
  end

  # The thread that wrote the dump, and the process it ran; and every
  # process that was running or collecting its garbage.
  defp calling(state, total) do
    thread = state.header["Calling Thread"]

    calling =
      with [tag, id] <- String.split(thread || "", ":"),
           true <- String.ends_with?(tag, "scheduler"),
           %{} = sched <- state.schedulers["#{scheduler_kind(tag)}#{id}"] do
        pid = sched["Current Process"]
        proc = Enum.find(state.procs, &(&1.pid == pid))

        %{thread: thread}
        |> put(:process, pid != "" && pid)
        |> put(:name, proc && proc[:name])
        |> put(:spawned_as, proc && proc[:spawned_as])
        |> put(:state, sched["Current Process State"])
        |> put(:current_function, function_in(sched["Current Process Program counter"] || ""))
        |> put(:stack, sched.stack != [] && stack(sched.stack))
      else
        _ -> %{thread: thread, note: "no process was running on this thread"}
      end

    active =
      for proc <- state.procs,
          active?(proc),
          proc.pid != calling[:process],
          do: describe_proc(proc, state, total)

    put(calling, :running_or_garbage_collecting, active != [] && active)
  end

  defp describe_ets(table, words) do
    %{table: table["name"] || table["table"], owner: table.owner}
    |> put(:type, table["type"])
    |> put(:objects, table["objects"])
    |> put(:memory_mb, table["words"] && mb(table["words"] * words))
  end

  defp atoms(state) do
    case state.atom_table do
      %{"entries" => n, "limit" => limit} -> %{count: n, limit: limit, percent: percent(n, limit)}
      _ -> %{count: int(state.header["Atoms"] || "")}
    end
  end

  defp top_counts(map, n) do
    map
    |> Enum.sort_by(&(-elem(&1, 1)))
    |> Enum.take(n)
    |> Enum.map(fn {k, count} -> %{what: k, count: count} end)
  end

  defp mailbox_sample(%{sample: [pid | _]} = state, syntax) do
    proc = Enum.find(state.procs, &(&1.pid == pid))

    if proc && (proc[:message_queue_len] || 0) > 0 do
      %{
        largest_mailbox: %{
          pid: pid,
          name: proc[:name],
          message_queue_len: proc[:message_queue_len],
          first_messages: messages(state, pid, syntax)
        }
      }
    else
      %{}
    end
  end

  defp mailbox_sample(_state, _syntax), do: %{}

  defp focus(_state, nil, _total, _syntax), do: %{}

  defp focus(state, pid, total, syntax) do
    case Enum.find(state.procs, &(&1.pid == pid)) do
      nil ->
        %{process: "no process #{pid} in the dump"}

      proc ->
        %{
          process:
            describe_proc(proc, state, total)
            |> put(:spawned_by, proc[:spawned_by])
            |> put(:links, proc[:links])
            |> put(:current_call, proc[:current_call])
            |> put(:heap_words, proc[:heap_words])
            |> put(
              :first_messages,
              (proc[:message_queue_len] || 0) > 0 && messages(state, pid, syntax)
            )
        }
    end
  end

  defp messages(state, pid, syntax) do
    heap = Map.get(state.heap, pid, %{})
    base64 = base64?(state.version)

    for line <- Enum.reverse(state.messages[pid] || []) do
      {term, _rest, _budget} =
        decode(line, %{heap: heap, literals: state.literals, base64: base64}, {8, 200})

      OtpDebugMcp.Format.inspect_as(term, syntax, limit: 50) |> truncate(1_000)
    end
  end

  defp base64?(version) do
    case version && Version.parse(version <> ".0") do
      {:ok, v} -> Version.compare(v, Version.parse!("0.3.0")) != :lt
      _ -> true
    end
  end

  ## Causes and findings

  defp cause(slogan, state) do
    cond do
      match =
          Regex.run(
            ~r/^(\w+): Cannot (?:re)?allocate (\d+) bytes of memory \(of type "([^"]+)"\)/,
            slogan
          ) ->
        [_, allocator, bytes, type] = match

        %{
          kind: "out_of_memory",
          explanation:
            "The VM asked the OS for #{bytes} more bytes (#{type}, from #{allocator}) and didn't " <>
              "get them, so it stopped. The node had #{mb(state.memory["total"])} MB. " <>
              allocator_hint(allocator, type),
          look_at:
            "findings, then processes.top_memory and largest_mailbox: usually one process or " <>
              "one kind of memory grew without bound"
        }

      match = Regex.run(~r/^Kernel pid terminated \(application_controller\) \((.*)\)$/s, slogan) ->
        [_, reason] = match
        application_cause(reason)

      match = Regex.run(~r/^Kernel pid terminated \(([^)]+)\) \((.*)\)$/s, slogan) ->
        [_, who, reason] = match

        %{
          kind: "kernel_process_died",
          explanation:
            "#{who}, one of the processes the node can't run without, exited (#{reason}), " <>
              "so the node stopped.",
          look_at: "the node's logs from just before, for why #{who} exited"
        }

      Regex.match?(~r/^Init terminating in do_boot/, slogan) ->
        %{
          kind: "boot_failed",
          explanation:
            "The node failed while booting: #{slogan}. Usually a module, application or " <>
              "config file that isn't where the boot script expects it.",
          look_at: "the reason in the slogan; the node never ran, so the processes don't matter"
        }

      Regex.match?(~r/no more index entries in atom_tab/, slogan) ->
        %{
          kind: "atom_table_full",
          explanation:
            "Every atom the node may have (#{state.atom_table["limit"]}) was used, and atoms are " <>
              "never freed: something creates atoms from data (binary_to_atom, list_to_atom, " <>
              "String.to_atom on input).",
          look_at: "the code that turns input into atoms; String.to_existing_atom avoids it"
        }

      match = Regex.run(~r/Received SIG(\w+)/, slogan) ->
        [_, signal] = match

        %{
          kind: "signal",
          explanation:
            "The node got SIG#{signal} and stopped. With SIGUSR1, someone (or a supervisor of " <>
              "the OS process, e.g. a health check) asked for this dump, usually because the " <>
              "node had stopped responding.",
          look_at:
            "running_when_it_died, the schedulers' run queues, and processes.top_message_queues: " <>
              "what was the node busy with"
        }

      Regex.match?(~r/^could not start kernel pid/, slogan) ->
        %{
          kind: "boot_failed",
          explanation: "A process the node needs failed to start: #{slogan}.",
          look_at: "the node's configuration (sys.config, vm.args)"
        }

      true ->
        %{
          kind: "halted",
          explanation:
            "The node stopped with this message: by erlang:halt/1 from code, with this message " <>
              "as its argument, or a fatal error in the VM.",
          look_at: "the code that calls halt with this message, or the slogan's error"
        }
    end
  end

  defp allocator_hint("eheap_alloc", _),
    do: "A process heap was growing: one process's data or mailbox got too big."

  defp allocator_hint("binary_alloc", _),
    do: "Binaries were growing: kept references to large or many binaries."

  defp allocator_hint("ets_alloc", _), do: "ETS tables were growing."
  defp allocator_hint(_, _), do: ""

  defp application_cause(reason) do
    {kind, app, why} =
      case Regex.run(
             ~r/^"?\{(application_terminated|application_start_failure),([^,]+),(.*)\}"?$/s,
             reason
           ) do
        [_, kind, app, why] -> {kind, app, why}
        nil -> {nil, nil, reason}
      end

    case kind do
      "application_start_failure" ->
        %{
          kind: "application_start_failure",
          application: app,
          explanation:
            "The application #{app} failed to start (#{why}), and it's permanent, so the node " <>
              "stopped.",
          look_at: "the reason; the node's logs from its start"
        }

      "application_terminated" ->
        %{
          kind: "application_terminated",
          application: app,
          explanation:
            "The application #{app} stopped (#{why}), and it's permanent, so the node stopped. " <>
              "An application stops when its top supervisor gives up: a child kept crashing, " <>
              "more often than the supervisor's restart intensity allows (by default 3 times " <>
              "in 5 seconds).",
          look_at:
            "the crashes that came before: the node's logs, or recent_errors and " <>
              "supervisor_restarts on the restarted node. The dump shows the node after the " <>
              "crashes, not them."
        }

      nil ->
        %{
          kind: "kernel_process_died",
          explanation:
            "The application controller exited (#{why}), so the node stopped: an application " <>
              "it couldn't do without stopped.",
          look_at: "the node's logs from just before"
        }
    end
  end

  defp findings(state, procs, total, words) do
    big = Enum.max_by(procs, &(&1[:memory_mb] || 0), fn -> nil end)
    big = big && Map.put_new(big, :share_of_memory, 0)
    oom? = (state.header["Slogan"] || "") =~ ~r"Cannot (re)?allocate"
    growing = Enum.filter(procs, &(&1[:state] == "Garbing"))
    queue = Enum.max_by(procs, &(&1[:message_queue_len] || 0), fn -> nil end)
    binary = state.memory["binary"]
    ets = state.memory["ets"]
    {spawned, spawned_count} = Enum.max_by(state.spawned_as, &elem(&1, 1), fn -> {nil, 0} end)
    {current, current_count} = Enum.max_by(state.current, &elem(&1, 1), fn -> {nil, 0} end)
    largest_table = Enum.max_by(state.ets, &(&1["words"] || 0), fn -> nil end)

    [
      big && total && big.share_of_memory >= 20 &&
        "#{label(big)} held #{big.share_of_memory}% of the node's memory (#{big.memory_mb} MB)" <>
          if((big[:message_queue_len] || 0) > 0,
            do: ", with #{big.message_queue_len} messages in its mailbox",
            else: ""
          ),
      queue && (queue[:message_queue_len] || 0) >= 10_000 &&
        "#{label(queue)} had #{queue.message_queue_len} messages waiting: it couldn't keep up " <>
          "with what it was sent",
      oom? && growing != [] &&
        "#{Enum.map_join(growing, ", ", &label/1)} " <>
          if(length(growing) == 1, do: "was", else: "were") <>
          " collecting garbage, so growing its heap, when memory ran out",
      binary && total && percent(binary, total) >= 50 &&
        "binaries were #{percent(binary, total)}% of the node's memory",
      ets && total && percent(ets, total) >= 50 && largest_table &&
        "ETS was #{percent(ets, total)}% of the node's memory; the largest table, " <>
          "#{largest_table["name"]}, #{mb((largest_table["words"] || 0) * words)} MB",
      state.proc_count >= 10_000 && spawned_count * 2 >= state.proc_count &&
        spawned != "proc_lib:init_p/5" &&
        "#{spawned_count} of the #{state.proc_count} processes were spawned as #{spawned}: " <>
          "a process leak?",
      state.proc_count >= 10_000 && current_count * 2 >= state.proc_count &&
        "#{current_count} of the #{state.proc_count} processes were in #{current}: " <>
          "a process leak, or processes stuck in the same place?",
      match?(%{"entries" => n, "limit" => l} when n * 10 >= l * 9, state.atom_table) &&
        "the atom table was #{percent(state.atom_table["entries"], state.atom_table["limit"])}% full"
    ]
    |> Enum.filter(&is_binary/1)
  end

  defp label(proc) do
    name = if proc[:name], do: " (#{proc.name})", else: ""
    "#{proc.pid}#{name}"
  end

  defp interpretation do
    """
    The dump is the node's state at the moment it died. slogan is its \
    last words and cause what they mean. findings are the things in the \
    dump that stand out. running_when_it_died is the process the dying \
    scheduler was running: on running out of memory, the one whose \
    allocation failed, often the one that grew. top_memory and \
    top_message_queues are the biggest processes, with their stacks \
    (innermost first: where each was); largest_mailbox decodes the first \
    messages of the longest mailbox, which say who sent them. A dump has \
    no logs: what led up to a crash is in the node's logs, or in \
    recent_errors on the node once it's running again. To see one process \
    in full, call crash_dump again with process: its pid.\
    """
  end

  defp mb(nil), do: nil
  defp mb(bytes), do: Float.round(bytes / 1_048_576, 1)

  defp percent(_part, 0), do: 0
  defp percent(part, whole), do: round(part * 100 / whole)

  defp put(map, _key, value) when value in [nil, false, ""], do: map
  defp put(map, key, value), do: Map.put(map, key, value)

  defp truncate(text, max) when byte_size(text) > max, do: String.slice(text, 0, max) <> "…"
  defp truncate(text, _max), do: text

  ## Heap terms

  @doc """
  Decode a term as the dump writes it (`H` pointers into the process's
  heap lines, `t` tuples, `l` conses, `A` atoms, ...), at most `depth`
  levels deep and `budget` terms in all: what's left out is shown as `…`.
  """
  def decode(text, _ctx, {depth, budget}) when depth <= 0 or budget <= 0,
    do: {more(), skip_term(text), {depth, budget}}

  def decode("H" <> rest, ctx, {depth, budget}) do
    {addr, rest} = hex_digits(rest)

    case lookup(ctx, addr) do
      nil ->
        {more(), rest, {depth, budget}}

      line ->
        {term, _, {_, budget}} = heap_term(line, ctx, {depth, budget - 1})
        {term, rest, {depth, budget}}
    end
  end

  def decode("N" <> rest, _ctx, limits), do: {[], rest, limits}

  def decode("I" <> rest, _ctx, limits) do
    {int, rest} = Integer.parse(rest)
    {int, rest, limits}
  end

  def decode("A" <> _ = text, _ctx, limits) do
    {atom, rest} = atom(text)
    {atom, rest, limits}
  end

  def decode("P" <> rest, _ctx, limits) do
    {id, rest} = id(rest)
    {%Printed{text: id}, rest, limits}
  end

  def decode("p" <> rest, _ctx, limits) do
    {id, rest} = id(rest)
    {%Printed{text: "#Port" <> id}, rest, limits}
  end

  def decode("S" <> rest, _ctx, limits), do: {String.trim_trailing(rest), "", limits}
  def decode(text, _ctx, limits), do: {more(), skip_term(text), limits}

  defp heap_term("l" <> rest, ctx, limits), do: list(rest, ctx, limits, [], 0)

  defp heap_term("t" <> rest, ctx, {depth, budget}) do
    {n, ":" <> rest} = hex(rest)
    {items, rest, {_, budget}} = elements(n, rest, ctx, {depth - 1, budget}, [])
    {List.to_tuple(items), rest, {depth, budget}}
  end

  defp heap_term("F" <> rest, _ctx, limits) do
    {n, ":" <> rest} = hex(rest)
    <<chars::binary-size(n), rest::binary>> = rest

    case Float.parse(chars) do
      {f, _} -> {f, rest, limits}
      :error -> {%Printed{text: chars}, rest, limits}
    end
  end

  defp heap_term("B16#" <> rest, _ctx, limits) do
    {n, rest} = hex(rest)
    {n, rest, limits}
  end

  defp heap_term("B-16#" <> rest, _ctx, limits) do
    {n, rest} = hex(rest)
    {-n, rest, limits}
  end

  defp heap_term("B" <> rest, _ctx, limits) do
    {n, rest} = Integer.parse(rest)
    {n, rest, limits}
  end

  defp heap_term("Yh" <> rest, ctx, limits) do
    {n, ":" <> rest} = hex(rest)
    {bytes(n, rest, ctx), "", limits}
  end

  defp heap_term("Yc" <> rest, _ctx, limits), do: {binary_ref(rest), "", limits}
  defp heap_term("Ys" <> rest, _ctx, limits), do: {binary_ref(rest), "", limits}

  defp heap_term("E" <> rest, ctx, limits) do
    {n, ":" <> rest} = hex(rest)

    term =
      try do
        rest |> encoded(n, ctx) |> :erlang.binary_to_term([:safe])
      rescue
        _ -> %Printed{text: "#Term<external>"}
      end

    {term, "", limits}
  end

  defp heap_term("Mf" <> rest, ctx, {depth, budget}) do
    {n, ":" <> rest} = hex(rest)
    {keys, rest, {_, budget}} = decode(rest, ctx, {depth - 1, budget})

    case rest do
      ":" <> rest when is_tuple(keys) ->
        {values, rest, {_, budget}} = elements(n, rest, ctx, {depth - 1, budget}, [])
        {Map.new(Enum.zip(Tuple.to_list(keys), values)), rest, {depth, budget}}

      _ ->
        {more(), "", {depth, budget}}
    end
  end

  defp heap_term("Mh" <> rest, ctx, {depth, budget}) do
    {_size, ":" <> rest} = hex(rest)
    {n, ":" <> rest} = hex(rest)
    {nodes, rest, {_, budget}} = elements(n, rest, ctx, {depth - 1, budget}, [])
    {nodes |> hashmap_pairs([]) |> Map.new(), rest, {depth, budget}}
  end

  defp heap_term("Mn" <> rest, ctx, {depth, budget}) do
    {n, ":" <> rest} = hex(rest)
    {nodes, rest, {_, budget}} = elements(n, rest, ctx, {depth, budget}, [])
    {{:hashmap_node, nodes}, rest, {depth, budget}}
  end

  defp heap_term("Rf" <> _, _ctx, limits), do: {%Printed{text: "#Fun<…>"}, "", limits}
  defp heap_term(_other, _ctx, limits), do: {more(), "", limits}

  # A list is a chain of conses, one heap line each: followed for the first
  # 20 elements.
  defp list(_rest, _ctx, limits, acc, 20), do: {Enum.reverse([more() | acc]), "", limits}

  defp list(text, ctx, {depth, budget}, acc, n) do
    {head, rest, {_, budget}} = decode(text, ctx, {depth - 1, budget})

    case rest do
      "|" <> rest -> list_tail(rest, ctx, {depth, budget}, [head | acc], n)
      _ -> {Enum.reverse([head | acc]), "", {depth, budget}}
    end
  end

  defp list_tail(rest, ctx, {depth, budget}, [head | acc], n) do
    case rest do
      "N" <> _ ->
        {Enum.reverse([head | acc]), "", {depth, budget}}

      "H" <> ptr ->
        {addr, _} = hex_digits(ptr)

        case lookup(ctx, addr) do
          "l" <> next when budget > 0 ->
            list(next, ctx, {depth, budget - 1}, [head | acc], n + 1)

          _ ->
            {tail, _, {_, budget}} = decode(rest, ctx, {depth - 1, budget})
            {improper(Enum.reverse([head | acc]), tail), "", {depth, budget}}
        end

      _ ->
        {tail, _, {_, budget}} = decode(rest, ctx, {depth - 1, budget})
        {improper(Enum.reverse([head | acc]), tail), "", {depth, budget}}
    end
  end

  defp improper(items, tail), do: items ++ tail

  defp lookup(ctx, addr), do: Map.get(ctx.heap, addr) || Map.get(ctx.literals, addr)

  defp elements(0, rest, _ctx, limits, acc), do: {Enum.reverse(acc), rest, limits}

  defp elements(n, text, ctx, limits, acc) do
    {term, rest, limits} = decode(text, ctx, limits)
    rest = with "," <> after_comma <- rest, do: after_comma
    elements(n - 1, rest, ctx, limits, [term | acc])
  end

  defp hashmap_pairs([], acc), do: acc
  defp hashmap_pairs([[k | v] | rest], acc), do: hashmap_pairs(rest, [{k, v} | acc])

  defp hashmap_pairs([{:hashmap_node, nodes} | rest], acc),
    do: hashmap_pairs(rest, hashmap_pairs(nodes, acc))

  defp hashmap_pairs([_ | rest], acc), do: hashmap_pairs(rest, acc)

  defp atom("A" <> rest) do
    {n, ":" <> rest} = hex(rest)
    <<name::binary-size(n), rest::binary>> = rest
    {String.to_atom(name), rest}
  end

  defp id(text) do
    [id, rest] = :binary.split(text, ">")
    {id <> ">", rest}
  end

  defp bytes(n, text, %{base64: true}) do
    case Base.decode64(binary_part(text, 0, min(byte_size(text), div(n + 2, 3) * 4))) do
      {:ok, bin} -> bin
      :error -> %Printed{text: "<<#{n} bytes>>"}
    end
  end

  defp bytes(n, text, _ctx) do
    case Base.decode16(binary_part(text, 0, min(byte_size(text), n * 2)), case: :mixed) do
      {:ok, bin} -> bin
      :error -> %Printed{text: "<<#{n} bytes>>"}
    end
  end

  defp encoded(text, n, ctx) do
    case bytes(n, text, ctx) do
      bin when is_binary(bin) -> bin
      _ -> raise ArgumentError
    end
  end

  # "<binary address>:<offset>:<size>", the bytes being elsewhere.
  defp binary_ref(text) do
    case String.split(text, ":") do
      [_, _, size | _] -> %Printed{text: "<<#{elem(hex(size), 0)} bytes>>"}
      _ -> %Printed{text: "<<…>>"}
    end
  end

  defp more, do: %Printed{text: "…"}

  defp skip_term(text) do
    case :binary.match(text, [",", "|", ":"]) do
      {pos, _} -> binary_part(text, pos, byte_size(text) - pos)
      :nomatch -> ""
    end
  end

  defp hex(text) do
    {digits, rest} = hex_digits(text)
    {if(digits == "", do: 0, else: String.to_integer(digits, 16)), rest}
  end

  defp hex_digits(text) do
    size = hex_length(text, 0)
    <<digits::binary-size(size), rest::binary>> = text
    {digits, rest}
  end

  defp hex_length(<<c, rest::binary>>, n) when c in ?0..?9 or c in ?a..?f or c in ?A..?F,
    do: hex_length(rest, n + 1)

  defp hex_length(_, n), do: n
end
