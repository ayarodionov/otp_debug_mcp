defmodule OtpDebugMcp.Errors do
  @moduledoc """
  The errors a node logs: crashes, supervisor reports, error and warning
  messages, grouped by who failed and why.

  Nothing is loaded onto the target. A watch is a process there (spawned
  from evaluated code, registered as `otp_debug_mcp_errors`) and a logger
  handler of the same name whose only filter, a fun, sends the watch every
  event at the handler's level and stops it there, so the handler module
  itself never runs. The watch formats each event as the node would
  (Elixir's translations included, as they're a primary filter), takes
  out who crashed, the reason and the stack, and keeps the last 500. It
  removes the handler when it's stopped or expires; a janitor process
  removes it if the watch is killed.

  Errors logged before a watch started are only in the node's log files:
  `log_files/1` reads the end of the files its logger handlers write and
  of a release's console log (run_erl's erlang.log.N).
  """

  alias OtpDebugMcp.{Checks, Format, Target}

  @name :otp_debug_mcp_errors
  @max_kept 500
  @levels ~w(emergency alert critical error warning notice info debug)a

  def levels, do: @levels

  @start ~S"""
  case whereis(Name) of
    W when is_pid(W) -> already_running;
    undefined ->
      Parent = self(),
      Ref = make_ref(),
      Fmt = #{template => [msg], single_line => false, chars_limit => 4000, depth => 40,
              legacy_header => false},
      Small = fun(T) ->
        case erts_debug:flat_size(T) > 1000 of
          true -> {'$text', unicode:characters_to_binary(
                     io_lib:format("~0tP", [T, 12], [{chars_limit, 1000}]))};
          false -> T
        end
      end,
      IsStack = fun([{M, F, A, Loc} | _]) when is_atom(M), is_atom(F), is_list(Loc),
                                             (is_integer(A) orelse is_list(A)) -> true;
                   (_) -> false
                end,
      Frames = fun(St) ->
        [{M, F, case is_list(A) of true -> length(A); false -> A end,
          proplists:get_value(file, Loc), proplists:get_value(line, Loc)}
         || {M, F, A, Loc} <- lists:sublist(St, 8)]
      end,
      Crash = fun(Kind, Who, Reason0, St0) ->
        {Reason, Stack} =
          case Reason0 of
            {R1, S1} ->
              case IsStack(S1) of true -> {R1, S1}; false -> {Reason0, St0} end;
            _ -> {Reason0, St0}
          end,
        Stack1 = case IsStack(Stack) of true -> Stack; false -> [] end,
        Called = case Stack1 of
          [{_, _, Args, _} | _] when is_list(Args) -> Small(Args);
          _ -> undefined
        end,
        #{kind => Kind, who => Small(Who), reason => Small(Reason), stack => Frames(Stack1),
          called_with => Called}
      end,
      SupName = fun({local, N}) -> N; ({global, N}) -> N; ({via, _, N}) -> N; (N) -> N end,
      Emulator = fun(F, [P, _, R]) when is_pid(P) ->
                       case catch lists:prefix("Error in process", unicode:characters_to_list(F)) of
                         true -> (Crash(process, P, R, []))#{crashed => P};
                         _ -> #{kind => log}
                       end;
                    (_, _) -> #{kind => log}
                 end,
      Describe = fun
        ({report, #{label := {gen_server, terminate}, name := N, reason := R}}) ->
          Crash(gen_server, N, R, []);
        ({report, #{label := {gen_statem, terminate}, name := N, reason := {C, R, S}}})
            when is_atom(C) ->
          Crash(gen_statem, N, R, S);
        ({report, #{label := {gen_statem, terminate}, name := N, reason := R}}) ->
          Crash(gen_statem, N, R, []);
        ({report, #{label := {gen_event, terminate}, name := N, handler := H, reason := R}}) ->
          Crash(gen_event, {N, H}, R, []);
        ({report, #{label := {proc_lib, crash}, report := [Info | _]}}) when is_list(Info) ->
          Who = case proplists:get_value(registered_name, Info, []) of
            [] -> case proplists:get_value(initial_call, Info) of
                    {M, F, A} when is_list(A) -> {M, F, length(A)};
                    I -> I
                  end;
            Registered -> Registered
          end,
          case proplists:get_value(error_info, Info) of
            {_, R, S} -> Crash(crash_report, Who, R, S);
            R -> Crash(crash_report, Who, R, [])
          end;
        ({report, #{label := {supervisor, Ctx}, report := R}}) when is_list(R) ->
          Off = proplists:get_value(offender, R, []),
          Child = case is_list(Off) of
            true -> proplists:get_value(id, Off, proplists:get_value(name, Off));
            false -> Off
          end,
          (Crash(supervisor, Child, proplists:get_value(reason, R), []))#{
            supervisor => Small(SupName(proplists:get_value(supervisor, R))), context => Ctx,
            crashed => case is_list(Off) of true -> proplists:get_value(pid, Off); false -> undefined end};
        ({report, #{label := {application_controller, Ctx}, report := R}}) when is_list(R) ->
          (Crash(application, proplists:get_value(application, R),
                 proplists:get_value(exited, R), []))#{context => Ctx};
        ({report, #{label := {'Elixir.Task.Supervisor', terminating}, report := #{reason := R} = T}}) ->
          Crash(task, maps:get(name, T, maps:get(function, T, undefined)), R, []);
        ({report, #{format := F, args := A}}) -> Emulator(F, A);
        ({F, A}) when is_list(A) -> Emulator(F, A);
        (_) -> #{kind => log}
      end,
      Entry = fun(#{level := Lv, msg := Msg, meta := Meta} = E) ->
        Text = try unicode:characters_to_binary(logger_formatter:format(E, Fmt)) of
                 B when is_binary(B) -> B;
                 _ -> <<"(could not format this event)">>
               catch _:_ -> <<"(could not format this event)">>
               end,
        About = try Describe(Msg) catch _:_ -> #{kind => log} end,
        %% Every report but the supervisor's is logged by the process that crashed.
        About#{at => maps:get(time, Meta, undefined), level => Lv,
               crashed => maps:get(crashed, About, maps:get(pid, Meta, undefined)),
               pid => maps:get(pid, Meta, undefined), mfa => maps:get(mfa, Meta, undefined),
               file => maps:get(file, Meta, undefined), line => maps:get(line, Meta, undefined),
               text => Text}
      end,
      Watch = fun() ->
        case catch register(Name, self()) of
          true ->
            Me = self(),
            Dropped = counters:new(1, []),
            Filter = fun(Event, {Collector, Counter}) ->
              case erlang:process_info(Collector, message_queue_len) of
                {message_queue_len, Queued} when Queued < 1000 -> Collector ! {log, Event};
                {message_queue_len, _} -> counters:add(Counter, 1, 1);
                undefined -> ok
              end,
              stop
            end,
            Config = #{level => Level, filter_default => stop,
                       filters => [{otp_debug_mcp, {Filter, {Me, Dropped}}}],
                       config => #{type => standard_error}},
            case logger:add_handler(Name, logger_std_h, Config) of
              ok ->
                spawn(fun() ->
                  MRef = erlang:monitor(process, Me),
                  receive
                    {'DOWN', MRef, _, _, _} ->
                      case logger:get_handler_config(Name) of
                        {ok, #{filters := [{_, {_, {Me, _}}}]}} -> logger:remove_handler(Name);
                        _ -> ok
                      end
                  end
                end),
                Parent ! {Ref, started},
                Started = os:system_time(microsecond),
                Deadline = erlang:monotonic_time(millisecond) + Duration,
                Report = fun(Q, Totals) ->
                  #{entries => queue:to_list(Q), totals => Totals,
                    dropped => counters:get(Dropped, 1), started => Started,
                    ends => Started + Duration * 1000, level => Level, kept_max => Max,
                    primary_level => maps:get(level, logger:get_primary_config())}
                end,
                Loop = fun LoopF(Q, Kept, Totals) ->
                  Left = max(0, Deadline - erlang:monotonic_time(millisecond)),
                  receive
                    {log, Ev} ->
                      En = Entry(Ev),
                      Q1 = queue:in(En, Q),
                      {Q2, Kept2} = case Kept >= Max of
                        true -> {queue:drop(Q1), Kept};
                        false -> {Q1, Kept + 1}
                      end,
                      LoopF(Q2, Kept2,
                            maps:update_with(maps:get(level, En), fun(C) -> C + 1 end, 1, Totals));
                    {read, From, ReadRef, Stop} ->
                      From ! {ReadRef, Report(Q, Totals)},
                      case Stop of true -> stopped; false -> LoopF(Q, Kept, Totals) end;
                    _ -> LoopF(Q, Kept, Totals)
                  after Left -> expired
                  end
                end,
                Loop(queue:new(), 0, #{}),
                logger:remove_handler(Name);
              {error, Why} ->
                Parent ! {Ref, {error, Why}}
            end;
          _ ->
            Parent ! {Ref, already_running}
        end
      end,
      spawn(Watch),
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

  @doc """
  Start a watch at `level` and above for `duration_ms`. Returns `:started`,
  or `:already_running` if there is one (only one at a time).
  """
  def start(level, duration_ms) do
    bindings = [Name: @name, Level: level, Max: @max_kept, Duration: duration_ms]

    case Checks.remote_eval(@start, bindings) do
      {:ok, :started} ->
        {:ok, :started}

      {:ok, :already_running} ->
        {:ok, :already_running}

      {:ok, {:error, reason}} ->
        {:error, "couldn't add a logger handler: #{Format.inspect(reason)}"}

      {:ok, :timeout} ->
        {:error, "the watch did not start within 5s"}

      err ->
        err
    end
  end

  @doc "What the running watch has caught (and stop it, if `stop`), or `:none`."
  def read(stop) do
    case Checks.remote_eval(@read, Name: @name, Stop: stop) do
      {:ok, {:ok, report}} -> {:ok, report}
      {:ok, :none} -> :none
      {:ok, :timeout} -> {:error, "the watch did not answer within 5s"}
      err -> err
    end
  end

  @doc """
  Listen for `duration_ms`, then return what was logged; or, if a watch is
  already running, what it has caught so far, without waiting.
  """
  def listen(level, duration_ms) do
    case read(false) do
      {:ok, report} ->
        {:ok, :watch, report}

      :none ->
        # The watch outlives the window a little, in case this call dies
        # before it reads, and then expires on its own.
        with {:ok, _} <- start(level, duration_ms + 10_000) do
          Process.sleep(duration_ms)

          case read(true) do
            {:ok, report} -> {:ok, :window, report}
            :none -> {:error, "the watch ended early"}
            err -> err
          end
        end

      err ->
        err
    end
  end

  ## Log files

  # The log files the node writes: its logger handlers' files (the newest
  # of a disk_log's wrap files) and a release's console log, from run_erl.
  @log_paths ~S"""
  Files = [F || #{config := #{file := F}} <- logger:get_handler_config()],
  Current = fun(F) ->
    case filelib:is_regular(F) of
      true -> [F];
      false ->
        %% disk_log wrap logs: File.1, File.2, ...; the newest is the one written.
        case lists:reverse(lists:keysort(1, [{filelib:last_modified(W), W}
                                             || W <- filelib:wildcard(F ++ ".*")])) of
          [{_, W} | _] -> [W];
          [] -> []
        end
    end
  end,
  RunErl = fun(Dir) ->
    case lists:reverse(lists:keysort(1, [{filelib:last_modified(L), L}
                                         || L <- filelib:wildcard(filename:join(Dir, "erlang.log.*"))])) of
      [{_, L} | _] -> [L];
      [] -> []
    end
  end,
  Dirs = [D || D <- [os:getenv("RUNNER_LOG_DIR"),
                     case os:getenv("RELEASE_TMP") of false -> false; T -> filename:join(T, "log") end,
                     filename:join(code:root_dir(), "log")],
               D =/= false],
  Paths = lists:usort(lists:append([Current(unicode:characters_to_list(F)) || F <- Files]
                                   ++ [RunErl(D) || D <- Dirs])),
  """

  @log_files @log_paths <>
               ~S"""
               %% All of a small file; of a big one its start and its end.
               Read = fun(P) ->
                 Size = filelib:file_size(P),
                 case file:open(P, [read, binary, raw]) of
                   {ok, Fd} ->
                     Pread = fun(At, N) -> case file:pread(Fd, At, N) of {ok, D} -> D; _ -> <<>> end end,
                     Data = case Size =< Head + Tail of
                       true -> {all, Pread(0, Size)};
                       false -> {parts, Pread(0, Head), Pread(Size - Tail, Tail)}
                     end,
                     file:close(Fd),
                     {P, Size, calendar:local_time_to_universal_time_dst(filelib:last_modified(P)), Data};
                   {error, Why} -> {P, Size, undefined, {error, Why}}
                 end
               end,
               [Read(P) || P <- Paths].
               """

  # Where the node's logs go, without reading them: its primary level, its
  # handlers, and the files they and run_erl write.
  @log_setup @log_paths <>
               ~S"""
               Handlers = [{Id, Module, maps:get(level, H, all),
                            case maps:get(config, H, #{}) of
                              #{file := F} -> unicode:characters_to_binary(F);
                              #{type := T} -> T;
                              _ -> undefined
                            end}
                           || #{id := Id, module := Module} = H <- logger:get_handler_config()],
               {maps:get(level, logger:get_primary_config()), Handlers,
                [{unicode:characters_to_binary(P), filelib:file_size(P),
                  calendar:local_time_to_universal_time_dst(filelib:last_modified(P))} || P <- Paths]}.
               """

  @doc """
  Where the node's logs go: `{primary_level, handlers, files}`, each handler
  `{id, module, level, file or type}`, each file `{path, size, modified}`.
  """
  def log_setup, do: Checks.remote_eval(@log_setup)

  @head_bytes 65_536
  @tail_bytes 196_608
  @entries_per_file 15
  @max_entry 1_500

  @doc """
  The newest entries at `level` and above in the node's log files: those
  its logger handlers write, and a release's console log.
  """
  def log_files(level) do
    case Checks.remote_eval(@log_files, Head: @head_bytes, Tail: @tail_bytes) do
      {:ok, files} -> {:ok, Enum.map(files, &describe_file(&1, level))}
      err -> err
    end
  end

  defp describe_file({path, size, _modified, {:error, reason}}, _level),
    do: %{file: to_string(path), size_bytes: size, unreadable: Format.inspect(reason)}

  defp describe_file({path, size, modified, data}, level) do
    {entries, read} =
      case data do
        {:all, all} ->
          {log_entries(all), "all of it"}

        {:parts, head, tail} ->
          # Parts start and end mid-line.
          {log_entries(head, drop_last: true) ++ log_entries(tail, drop_first: true),
           "its first #{div(@head_bytes, 1024)} KB and last #{div(@tail_bytes, 1024)} KB"}
      end

    entries = Enum.filter(entries, &at_least?(&1.level, level))

    %{
      file: to_string(path),
      size_bytes: size,
      modified: modified(modified),
      read: read,
      matching_entries: length(entries),
      groups: file_groups(entries)
    }
  end

  # Entries that say the same (but for numbers and pids) together, in the
  # order they first appear, so an error logged once isn't lost among a
  # loop's thousand: each with how often, and its first and latest text.
  defp file_groups(entries) do
    groups =
      entries
      |> Enum.with_index()
      |> Enum.group_by(fn {e, _} -> normalize(e.text) end)
      |> Enum.map(fn {_key, [{first, at} | _] = all} ->
        {latest, _} = List.last(all)

        %{level: first.level, entries: length(all), first: truncate(first.text, @max_entry)}
        |> put_if(length(all) > 1, :latest, truncate(latest.text, @max_entry))
        |> Map.put(:at, at)
      end)
      |> Enum.sort_by(& &1.at)
      |> Enum.map(&Map.delete(&1, :at))

    # The first groups, and the newest.
    if length(groups) > @entries_per_file,
      do: Enum.take(groups, 5) ++ Enum.take(groups, 5 - @entries_per_file),
      else: groups
  end

  @doc "A file's modification time, as `log_setup/0` gives it, in ISO 8601."
  def modified_at(utc), do: modified(utc)

  defp modified([{{_, _, _}, {_, _, _}} = utc | _]), do: datetime(utc)
  defp modified({{_, _, _}, {_, _, _}} = utc), do: datetime(utc)
  defp modified(_), do: nil

  defp datetime(erl) do
    erl |> NaiveDateTime.from_erl!() |> DateTime.from_naive!("Etc/UTC") |> DateTime.to_iso8601()
  end

  # An entry starts at a line that begins like a log line (a date or time,
  # a level in brackets, a legacy report header, a JSON object); the lines
  # after it that don't are its continuation. A log in no format we know
  # is taken a line at a time.
  @entry_start ~r/^(\d{4}-\d\d-\d\d[T ]\d\d:\d\d|\d\d:\d\d:\d\d|\[[a-z]+\]|=[A-Z ]+REPORT====|\{")/
  @level_word ~r/(?:^|[\s\[":=])(emergency|alert|critical|error|warning|warn|notice|info|debug|crash|supervisor)(?=[\]":\s]|$| report)/i

  @doc false
  def log_entries(data, opts \\ []) do
    lines = data |> to_string_lossy() |> String.split(~r/\r?\n/)
    lines = if opts[:drop_first], do: Enum.drop(lines, 1), else: lines
    lines = if opts[:drop_last], do: Enum.drop(lines, -1), else: lines
    known? = Enum.any?(lines, &Regex.match?(@entry_start, &1))

    lines
    |> Enum.reject(&(&1 == ""))
    |> Enum.chunk_while(
      nil,
      fn line, acc ->
        cond do
          not known? or Regex.match?(@entry_start, line) ->
            if acc, do: {:cont, acc, [line]}, else: {:cont, [line]}

          acc ->
            {:cont, [line | acc]}

          true ->
            {:cont, nil}
        end
      end,
      fn
        nil -> {:cont, nil}
        acc -> {:cont, acc, nil}
      end
    )
    |> Enum.map(fn lines ->
      [first | _] = lines = Enum.reverse(lines)
      %{level: line_level(first), text: Enum.join(lines, "\n")}
    end)
  end

  defp line_level(line) do
    case Regex.run(@level_word, String.slice(line, 0, 120), capture: :all_but_first) do
      [word] ->
        case String.downcase(word) do
          "warn" -> :warning
          w when w in ["crash", "supervisor"] -> :error
          w -> String.to_existing_atom(w)
        end

      nil ->
        nil
    end
  end

  defp to_string_lossy(data) do
    case :unicode.characters_to_binary(data) do
      bin when is_binary(bin) -> bin
      _ -> for <<c <- data>>, into: "", do: if(c < 128, do: <<c>>, else: "?")
    end
  end

  defp at_least?(nil, _level), do: false

  defp at_least?(entry_level, level),
    do: rank(entry_level) <= rank(level)

  defp rank(level), do: Enum.find_index(@levels, &(&1 == level)) || length(@levels)

  ## Summaries

  @max_groups 10
  @max_example 2_000

  @doc """
  A watch's report as the tool returns it: totals, and its events grouped
  by who failed and why (crashes), or by where and what was logged.
  """
  def summarize(report) do
    # Erlang's undefined, for metadata the node didn't give.
    entries =
      Enum.map(report.entries, fn e ->
        Map.new(e, fn {k, v} -> {k, if(v == :undefined, do: nil, else: v)} end)
      end)

    names = names(entries)

    groups =
      entries
      |> Enum.map(&describe_entry(&1, names))
      |> Enum.group_by(& &1.key)
      |> Enum.map(fn {_key, entries} -> group(entries) end)
      |> Enum.sort_by(&{rank(&1.level), -&1.events})

    deadlocks = deadlocks(entries, names)

    %{
      events: Enum.sum(Map.values(report.totals)),
      by_level: report.totals,
      kept: length(report.entries),
      dropped_while_overloaded: report.dropped,
      groups: Enum.take(groups, @max_groups)
    }
    |> put_if(deadlocks != [], :deadlocks, deadlocks)
    |> put_if(length(groups) > @max_groups, :more_groups, length(groups) - @max_groups)
    |> put_if(
      Enum.sum(Map.values(report.totals)) > length(report.entries),
      :note,
      "only the last #{report.kept_max} events are kept; counts in groups are of those"
    )
  end

  defp describe_entry(%{kind: :log} = e, _names) do
    first = e.text |> String.split("\n", parts: 2) |> hd()
    where = location(e)
    Map.merge(e, %{key: {:log, where, normalize(first)}, where: where, first_line: first})
  end

  # A process that isn't registered is named by its pid, which changes on
  # every restart: then by what another report of the same crash says,
  # and failing that by where it failed.
  defp describe_entry(e, names) do
    reason = reason_text(e.reason)
    who = names[e.crashed] || name(e)
    top = with [frame | _] <- e.stack, do: frame(frame), else: (_ -> nil)

    Map.merge(e, %{
      key: {:crash, who || top, normalize(reason)},
      who_text: who || "processes that aren't registered",
      reason_text: reason
    })
  end

  # Processes that crashed calling each other in a cycle, within
  # @deadlock_window_us of each other: a deadlock that a call's timeout
  # broke (the first to time out crashes, and the others' calls to it end
  # with it). Each cycle of names, however often it happened.
  @deadlock_window_us 2_000_000
  @call_modules [:gen_server, :gen_statem, GenServer]

  defp deadlocks(entries, names) do
    crashes =
      entries
      |> Enum.filter(&(&1.kind not in [:log, :supervisor] and is_pid(&1[:crashed])))
      |> Enum.group_by(& &1.crashed)
      |> Enum.flat_map(fn {pid, es} ->
        case Enum.find_value(es, &call_in(&1.reason)) do
          nil ->
            []

          {server, request} ->
            [
              %{
                pid: pid,
                at:
                  es |> Enum.map(& &1.at) |> Enum.filter(&is_integer/1) |> Enum.min(fn -> nil end),
                aliases: [pid | for(%{who: w} <- es, is_atom(w) and w != nil, do: w)],
                server: server,
                request: request,
                name: names[pid] || Enum.find_value(es, &name/1) || Format.inspect(pid)
              }
            ]
        end
      end)

    by_pid = Map.new(crashes, &{&1.pid, &1})

    edges =
      Map.new(crashes, fn c ->
        callee =
          Enum.find(crashes, fn o ->
            o.pid != c.pid and called?(c.server, o.aliases) and near?(c.at, o.at)
          end)

        {c.pid, callee && callee.pid}
      end)

    edges
    |> Map.keys()
    |> Enum.flat_map(&cycle(&1, edges, [&1]))
    |> Enum.uniq_by(&Enum.sort/1)
    |> Enum.map(fn cycle -> Enum.map(cycle, &by_pid[&1]) end)
    |> Enum.group_by(fn cycle -> cycle |> Enum.map(& &1.name) |> Enum.sort() end)
    |> Enum.map(fn {_names, [cycle | _] = all} ->
      ats = all |> List.flatten() |> Enum.map(& &1.at) |> Enum.filter(&is_integer/1)

      %{
        times: length(all),
        first: time(Enum.min(ats, fn -> nil end)),
        last: time(Enum.max(ats, fn -> nil end)),
        calls:
          for c <- cycle do
            %{
              who: c.name,
              was_calling: by_pid[edges[c.pid]].name,
              request: truncate(Format.inspect(c.request, limit: 10), 300)
            }
          end
      }
    end)
  end

  # The call a process crashed in: the outermost one in its exit reason,
  # {Reason, {gen_server, call, [Server, Request | _]}} (gen_statem's and
  # GenServer's alike), Reason being timeout or the callee's own exit.
  defp call_in({_, {mod, :call, [server, request | _]}}) when mod in @call_modules,
    do: {server, request}

  defp call_in(_), do: nil

  defp called?({name, node}, aliases) when is_atom(node), do: called?(name, aliases)
  defp called?({:global, name}, aliases), do: called?(name, aliases)
  defp called?({:via, _, name}, aliases), do: called?(name, aliases)
  defp called?(server, aliases), do: server in aliases

  defp near?(a, b) when is_integer(a) and is_integer(b), do: abs(a - b) <= @deadlock_window_us
  defp near?(_, _), do: false

  defp cycle(pid, edges, path) do
    case edges[pid] do
      nil ->
        []

      next ->
        case Enum.find_index(path, &(&1 == next)) do
          nil -> cycle(next, edges, path ++ [next])
          0 -> [path]
          _ -> []
        end
    end
  end

  # The best name each crashed process has in any report: its registered
  # name, its id under its supervisor, or what it was spawned to run.
  defp names(entries) do
    entries
    |> Enum.flat_map(fn e ->
      case {e.kind != :log && name(e), e[:crashed]} do
        {name, pid} when is_binary(name) and is_pid(pid) -> [{pid, {name_rank(e), name}}]
        _ -> []
      end
    end)
    |> Enum.group_by(&elem(&1, 0), &elem(&1, 1))
    |> Map.new(fn {pid, names} -> {pid, names |> Enum.min() |> elem(1)} end)
  end

  defp name(%{who: who}) when is_pid(who) or who in [nil, [], :undefined], do: nil

  defp name(%{who: {m, f, a}}) when is_atom(m) and is_atom(f) and is_integer(a),
    do: function(m, f, a)

  defp name(%{who: who}), do: Format.inspect(who, limit: 10)

  defp name_rank(%{kind: :supervisor}), do: 1
  defp name_rank(%{who: who}) when is_atom(who), do: 0
  defp name_rank(_), do: 2

  @report_names %{
    gen_server: "gen_server terminated",
    gen_statem: "gen_statem terminated",
    gen_event: "gen_event handler crashed",
    crash_report: "crash report",
    supervisor: "supervisor report",
    application: "application exited",
    task: "task crashed",
    process: "process crashed"
  }

  # The most telling report of a crash, for its example.
  @preference [
    :gen_server,
    :gen_statem,
    :gen_event,
    :task,
    :crash_report,
    :process,
    :supervisor,
    :application
  ]

  defp group([%{kind: :log} | _] = entries) do
    latest = List.last(entries)

    %{
      kind: "log",
      level: worst(entries),
      events: length(entries),
      message: truncate(latest.first_line, 300),
      first: time(hd(entries).at),
      last: time(latest.at),
      example: truncate(latest.text, @max_example)
    }
    |> put_if(latest.where, :logged_at, latest.where)
    |> put_if(processes(entries) > 1, :processes, processes(entries))
  end

  defp group(entries) do
    example =
      Enum.min_by(
        Enum.reverse(entries),
        &(Enum.find_index(@preference, fn k -> k == &1.kind end) || 99)
      )

    with_stack = entries |> Enum.reverse() |> Enum.find(&(&1.stack != []))
    supervisors = entries |> Enum.map(&Map.get(&1, :supervisor)) |> Enum.reject(&is_nil/1)

    %{
      kind: "crash",
      level: worst(entries),
      events: length(entries),
      who: example.who_text,
      reason: example.reason_text,
      reports: entries |> Enum.map(&@report_names[&1.kind]) |> Enum.frequencies(),
      processes: entries |> Enum.map(& &1.crashed) |> distinct(),
      first: time(hd(entries).at),
      last: time(List.last(entries).at),
      example: truncate(example.text, @max_example)
    }
    |> put_if(with_stack, :stack, with_stack && Enum.map(with_stack.stack, &frame/1))
    |> put_if(
      with_stack && with_stack.called_with,
      :called_with,
      with_stack && with_stack.called_with && truncate(reason_text(with_stack.called_with), 500)
    )
    |> put_if(supervisors != [], :supervisor, Format.inspect(List.last(supervisors)))
  end

  defp processes(entries), do: entries |> Enum.map(& &1.pid) |> distinct()

  defp distinct(pids), do: pids |> Enum.filter(&is_pid/1) |> Enum.uniq() |> length()

  defp worst(entries), do: entries |> Enum.map(& &1.level) |> Enum.min_by(&rank/1)

  defp reason_text({:"$text", text}), do: text

  defp reason_text(%{__exception__: true, __struct__: mod} = e) do
    case e do
      %{message: message} when is_binary(message) -> "#{inspect(mod)}: #{message}"
      _ -> Format.inspect(e, limit: 15)
    end
  end

  defp reason_text(reason), do: reason |> Format.inspect(limit: 15) |> truncate(500)

  # Numbers, pids and references differ from one occurrence to the next.
  defp normalize(text) do
    text
    |> String.slice(0, 1_000)
    |> String.replace(~r/#(Ref|Port|PID)<[^>]*>|<[\d.]+>/, "<id>")
    |> String.replace(~r/\d+/, "N")
    |> String.slice(0, 200)
  end

  defp location(%{mfa: {m, f, a}} = e) when is_atom(m) and is_atom(f) and is_integer(a),
    do: function(m, f, a) <> line(e[:file], e[:line])

  defp location(%{file: file} = e) when is_binary(file) or is_list(file),
    do: file_name(file) <> line_only(e[:line])

  defp location(_), do: nil

  defp line(nil, _), do: ""
  defp line(file, nil), do: " (#{file_name(file)})"
  defp line(file, line), do: " (#{file_name(file)}:#{line})"

  defp line_only(nil), do: ""
  defp line_only(line), do: ":#{line}"

  defp frame({m, f, a, file, _line}) when file in [nil, :undefined], do: function(m, f, a)
  defp frame({m, f, a, file, line}), do: function(m, f, a) <> line(file, line)

  defp function(m, f, a) do
    case {Target.syntax(Target.connected_node()), Atom.to_string(m)} do
      {:erlang, _} -> "#{erlang_atom(m)}:#{erlang_atom(f)}/#{a}"
      {_, "Elixir." <> mod} -> "#{mod}.#{elixir_name(f)}/#{a}"
      {_, mod} -> "#{inspect(String.to_atom(mod))}.#{elixir_name(f)}/#{a}"
    end
  end

  defp erlang_atom(atom), do: atom |> :io_lib.write_atom() |> IO.chardata_to_string()

  # As Elixir prints a function's name: quoted when it isn't an identifier.
  defp elixir_name(f) do
    case inspect(f) do
      ":" <> name -> name
      name -> name
    end
  end

  defp file_name(file) do
    file = to_string(file)
    if Path.type(file) == :absolute, do: Path.basename(file), else: file
  end

  defp time(us) when is_integer(us),
    do: us |> DateTime.from_unix!(:microsecond) |> DateTime.to_iso8601()

  defp time(_), do: nil

  defp truncate(text, max) when byte_size(text) > max,
    do: String.slice(text, 0, max) <> "… (truncated)"

  defp truncate(text, _max), do: text

  defp put_if(map, false, _key, _value), do: map
  defp put_if(map, nil, _key, _value), do: map
  defp put_if(map, _cond, key, value), do: Map.put(map, key, value)

  @doc "A watch's start and end, and the levels it sees."
  def window(report) do
    %{
      started: time(report.started),
      ends: time(report.ends),
      level: report.level,
      node_primary_level: report.primary_level
    }
  end
end
