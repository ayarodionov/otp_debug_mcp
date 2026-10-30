defmodule OtpDebugMcp.VmConfig do
  @moduledoc """
  How the VM is set up, against what it runs on: its schedulers against
  the CPUs it may use (the container's CPU quota, the CPUs its affinity
  allows), its memory against the container's memory limit, its limits
  (ports, ETS tables, the OS's open files) against what's in use, and
  settings that cost in production (busy-waiting schedulers in a
  container, debug logging, no JIT).

  The container's limits come from the cgroup files (v2: cpu.max,
  memory.max; v1: cpu.cfs_quota_us, memory.limit_in_bytes), and the OS
  process's from /proc/self, on Linux; elsewhere those parts are left
  out. The emulator flags (+S, +sbwt...) are read from the command line
  (/proc/self/cmdline) and ERL_FLAGS, ERL_AFLAGS and ERL_ZFLAGS.
  Nothing is changed.
  """

  alias OtpDebugMcp.{Checks, Format}

  @snapshot ~S"""
  Read = fun(P) -> case file:read_file(P) of {ok, B} -> string:trim(B); _ -> undefined end end,
  Int = fun(undefined) -> undefined;
           (B) -> case catch binary_to_integer(B) of N when is_integer(N) -> N; _ -> undefined end
        end,
  Info = fun(K) -> case catch erlang:system_info(K) of {'EXIT', _} -> undefined; V -> V end end,
  %% The container's CPU quota, in CPUs, and its memory limit and use.
  Cpu = case Read(CgroupRoot ++ "/cpu.max") of
    undefined ->
      case {Int(Read(CgroupRoot ++ "/cpu/cpu.cfs_quota_us")), Int(Read(CgroupRoot ++ "/cpu/cpu.cfs_period_us"))} of
        {Q, P} when is_integer(Q), Q > 0, is_integer(P), P > 0 -> {cgroup_v1, Q / P, P};
        {-1, _} -> {cgroup_v1, unlimited, undefined};
        _ -> undefined
      end;
    CpuMax ->
      case binary:split(CpuMax, <<" ">>) of
        [<<"max">> | _] -> {cgroup_v2, unlimited, undefined};
        [Q, P] -> case {Int(Q), Int(P)} of
                    {Qi, Pi} when is_integer(Qi), is_integer(Pi), Pi > 0 -> {cgroup_v2, Qi / Pi, Pi};
                    _ -> undefined
                  end;
        _ -> undefined
      end
  end,
  %% How often the kernel throttled the container: cpu.stat's counters
  %% (v2: nr_periods, nr_throttled, throttled_usec; v1 in cpu/, in ns),
  %% now and a second later.
  CpuStat = fun() ->
    case Read(CgroupRoot ++ "/cpu.stat") of
      undefined -> Read(CgroupRoot ++ "/cpu/cpu.stat");
      B -> B
    end
  end,
  Stat = fun(undefined) -> undefined;
            (B) -> maps:from_list([{K, Int(V)} || Line <- binary:split(B, <<"\n">>, [global]),
                                                  [K, V] <- [binary:split(Line, <<" ">>)]])
         end,
  Stat0 = Stat(CpuStat()),
  timer:sleep(StatMs),
  Stat1 = Stat(CpuStat()),
  Mem = case Read(CgroupRoot ++ "/memory.max") of
    undefined ->
      case Int(Read(CgroupRoot ++ "/memory/memory.limit_in_bytes")) of
        %% v1 says "no limit" with a number near 2^63.
        L when is_integer(L), L < 1 bsl 60 -> {cgroup_v1, L, Int(Read(CgroupRoot ++ "/memory/memory.usage_in_bytes"))};
        L when is_integer(L) -> {cgroup_v1, unlimited, Int(Read(CgroupRoot ++ "/memory/memory.usage_in_bytes"))};
        _ -> undefined
      end;
    <<"max">> -> {cgroup_v2, unlimited, Int(Read(CgroupRoot ++ "/memory.current"))};
    M -> {cgroup_v2, Int(M), Int(Read(CgroupRoot ++ "/memory.current"))}
  end,
  %% The OS process: resident memory, open files and their limit, and the
  %% command line's emulator flags.
  Status = case Read(ProcRoot ++ "/status") of
    undefined -> [];
    S -> [{K, V} || Line <- binary:split(S, <<"\n">>, [global]),
                    [K, V] <- [binary:split(Line, <<":">>)]]
  end,
  Rss = case proplists:get_value(<<"VmRSS">>, Status) of
    undefined -> undefined;
    R -> case string:split(string:trim(R), " ") of [N, _] -> Int(N); _ -> undefined end
  end,
  Files = case Read(ProcRoot ++ "/limits") of
    undefined -> undefined;
    Lim -> case [L || L <- binary:split(Lim, <<"\n">>, [global]), binary:match(L, <<"Max open files">>) =/= nomatch] of
             [Line | _] -> case string:lexemes(binary:part(Line, 14, byte_size(Line) - 14), " ") of
                             [Soft, Hard | _] -> {Int(Soft), Int(Hard)};
                             _ -> undefined
                           end;
             [] -> undefined
           end
  end,
  OpenFiles = case file:list_dir(ProcRoot ++ "/fd") of {ok, Fds} -> length(Fds); _ -> undefined end,
  Cmdline = case file:read_file(ProcRoot ++ "/cmdline") of
    {ok, C} -> [A || A <- binary:split(C, <<0>>, [global]), A =/= <<>>];
    _ -> []
  end,
  Env = [{V, list_to_binary(E)} || V <- ["ERL_FLAGS", "ERL_AFLAGS", "ERL_ZFLAGS"], E <- [os:getenv(V)], is_list(E)],
  Logger = case catch logger:get_primary_config() of #{level := Lv} -> Lv; _ -> undefined end,
  {ok,
   [{K, Info(K)} || K <- [otp_release, version, system_architecture, emu_flavor, emu_type, wordsize,
                          schedulers, schedulers_online, dirty_cpu_schedulers, dirty_cpu_schedulers_online,
                          dirty_io_schedulers, logical_processors, logical_processors_available,
                          logical_processors_online, cpu_quota, scheduler_bind_type, thread_pool_size,
                          process_limit, process_count, port_limit, port_count, atom_limit, atom_count,
                          ets_limit, ets_count, dist_buf_busy_limit, fullsweep_after, min_heap_size]],
   os:type(), {Cpu, Stat0, Stat1}, Mem, Rss, Files, OpenFiles, Cmdline, Env, Logger,
   catch code:get_mode(), catch net_kernel:get_net_ticktime(), erlang:memory(total)}.
  """

  # How long between the two readings of the container's throttling.
  @stat_ms 1_000

  @doc """
  The VM's configuration and findings. `cgroup_root` and `proc_root` say
  where the node reads its cgroup and process files (tests point them
  elsewhere).
  """
  def run(opts \\ []) do
    bindings = [
      CgroupRoot: String.to_charlist(opts[:cgroup_root] || "/sys/fs/cgroup"),
      ProcRoot: String.to_charlist(opts[:proc_root] || "/proc/self"),
      StatMs: opts[:stat_ms] || @stat_ms
    ]

    with {:ok,
          {:ok, info, os, cpu, mem, rss, files, open, cmdline, env, logger, mode, ticktime, total}} <-
           Checks.remote_eval(@snapshot, bindings) do
      # Erlang's undefined, for what the node couldn't say, as nil.
      [rss, files, open, logger] = Enum.map([rss, files, open, logger], &nil_if_undefined/1)
      info = Map.new(info, fn {k, v} -> {k, nil_if_undefined(v)} end)
      flags = flags(cmdline, env)
      linux? = match?({:unix, :linux}, os)

      report =
        %{
          runtime: runtime(info, mode, logger),
          cpu: cpu(info, cpu, flags),
          memory: memory(total, mem, rss),
          limits: limits(info, files, open),
          distribution: %{
            net_ticktime_s: ticktime,
            dist_buf_busy_limit_bytes: info[:dist_buf_busy_limit]
          }
        }
        |> put(:emulator_flags, flags != %{} && flags)
        |> put(
          :note,
          !linux? && "not Linux: no container limits or /proc to read; the VM's own settings only"
        )

      notes = findings(report, info) |> Enum.sort_by(fn {level, _} -> rank(level) end)

      {:ok, status(notes), Map.put(report, :notes, for({l, t} <- notes, do: "#{l}: #{t}")),
       interpretation()}
    else
      {:error, _} = err -> err
      other -> {:error, Format.inspect(other)}
    end
  end

  defp nil_if_undefined(:undefined), do: nil
  defp nil_if_undefined(v), do: v

  # -- Sections -------------------------------------------------------------------

  defp runtime(info, mode, logger) do
    %{
      otp_release: to_string(info[:otp_release]),
      erts: to_string(info[:version]),
      architecture: to_string(info[:system_architecture]),
      code_mode: mode,
      logger_level: logger
    }
    |> put(:emulator, info[:emu_flavor])
  end

  defp cpu(info, {cpu, stat0, stat1}, flags) do
    {source, quota, period} =
      case cpu do
        {source, quota, period} -> {source, quota, period}
        _ -> {nil, nil, nil}
      end

    %{
      schedulers: info[:schedulers],
      schedulers_online: info[:schedulers_online],
      dirty_cpu_schedulers_online: info[:dirty_cpu_schedulers_online],
      dirty_io_schedulers: info[:dirty_io_schedulers],
      logical_processors: info[:logical_processors],
      logical_processors_available: info[:logical_processors_available]
    }
    |> put(:cpu_quota, quota && quota(quota))
    |> put(:cpu_quota_period_ms, is_integer(period) && div(period, 1000))
    |> put(:cpu_quota_from, source)
    |> put(:throttled, throttled(stat0, stat1))
    |> put(:busy_wait, busy_wait(flags))
    |> put(
      :scheduler_bind_type,
      info[:scheduler_bind_type] not in [nil, :unbound] && info[:scheduler_bind_type]
    )
  end

  # Since the container started, and over the last second: the share of
  # quota periods in which the kernel stopped it, and for how long.
  defp throttled(
         %{"nr_periods" => p0, "nr_throttled" => t0} = s0,
         %{"nr_periods" => p1, "nr_throttled" => t1} = s1
       )
       when is_integer(p0) and is_integer(p1) and p1 > 0 do
    us = fn s ->
      s["throttled_usec"] || (s["throttled_time"] && div(s["throttled_time"], 1000))
    end

    %{
      periods_since_start: p1,
      throttled_share_since_start: Float.round(t1 / p1, 3)
    }
    |> put(
      :last_second,
      p1 > p0 &&
        %{
          periods: p1 - p0,
          throttled: t1 - t0,
          throttled_ms:
            (is_integer(us.(s0)) and is_integer(us.(s1))) && div(us.(s1) - us.(s0), 1000)
        }
    )
  end

  defp throttled(_, _), do: false

  defp quota(:unlimited), do: "unlimited"
  defp quota(q) when is_float(q), do: Float.round(q, 2)
  defp quota(q), do: q

  # The busy-wait settings given, and the defaults for the rest.
  defp busy_wait(flags) do
    %{
      sbwt: flags["+sbwt"] || "medium (default)",
      sbwtdcpu: flags["+sbwtdcpu"] || "short (default)",
      sbwtdio: flags["+sbwtdio"] || "short (default)"
    }
  end

  defp memory(total, mem, rss) do
    base = %{vm_total_bytes: total} |> put(:os_resident_bytes, rss && rss * 1024)

    case mem do
      {source, limit, current} ->
        base
        |> Map.put(:container_limit_bytes, if(limit == :unlimited, do: "unlimited", else: limit))
        |> put(:container_current_bytes, current)
        |> Map.put(:limit_from, source)

      _ ->
        base
    end
  end

  defp limits(info, files, open) do
    used = fn count, limit ->
      if is_integer(count) and is_integer(limit) and limit > 0,
        do: %{used: count, limit: limit, share: Float.round(count / limit, 3)},
        else: false
    end

    %{}
    |> put(:processes, used.(info[:process_count], info[:process_limit]))
    |> put(:ports, used.(info[:port_count], info[:port_limit]))
    |> put(:atoms, used.(info[:atom_count], info[:atom_limit]))
    |> put(:ets_tables, used.(info[:ets_count], info[:ets_limit]))
    |> put(
      :open_files,
      case files do
        {soft, hard} when is_integer(soft) ->
          (used.(open, soft) || %{limit: soft}) |> Map.put(:hard_limit, hard)

        _ ->
          false
      end
    )
  end

  @flags ~w(+S +SDcpu +SDio +sbwt +sbwtdcpu +sbwtdio +sbt +P +Q +A +zdbbl +K)

  # Emulator flags from the command line and the environment, last wins.
  # beam.smp gets them from erl as -S, -sbwt..., before its first "--";
  # ERL_FLAGS and the like write them +S, +sbwt.
  defp flags(cmdline, env) do
    emulator =
      cmdline
      |> Enum.drop(1)
      |> Enum.take_while(&(&1 != "--"))
      |> Enum.map(fn
        "-" <> flag -> "+" <> flag
        other -> other
      end)

    (emulator ++ Enum.flat_map(env, fn {_, v} -> String.split(v) end))
    |> Enum.chunk_every(2, 1, [nil])
    |> Enum.filter(fn [flag, _] -> flag in @flags end)
    |> Map.new(fn [flag, value] -> {flag, value} end)
  end

  # -- Findings -------------------------------------------------------------------

  defp findings(r, info) do
    c = r.cpu
    quota = c[:cpu_quota]
    online = c.schedulers_online
    limited? = is_number(quota)
    cpus = if limited?, do: max(ceil(quota), 1)

    sched =
      cond do
        limited? and online > cpus ->
          [
            {:warning,
             "#{online} schedulers online, but the container's CPU quota is #{quota} CPUs#{if c[:cpu_quota_period_ms], do: " per #{c.cpu_quota_period_ms} ms", else: ""}#{throttle_text(c[:throttled])}: the schedulers compete for that time, and once the VM has used its quota in a period the kernel stops all of it until the next, so latency jumps by up to the period. Run as many schedulers as the quota: +S #{cpus}:#{cpus}#{if r[:emulator_flags]["+S"], do: " (the command line sets +S #{r.emulator_flags["+S"]})", else: ""}; without a +S, OTP 23 and later follow the quota themselves"}
          ]

        is_integer(c.logical_processors_available) and online > c.logical_processors_available ->
          [
            {:warning,
             "#{online} schedulers online on #{c.logical_processors_available} CPUs the process may run on (its CPU affinity, a cpuset): schedulers share CPUs and wait for each other. +S #{c.logical_processors_available}:#{c.logical_processors_available}"}
          ]

        true ->
          []
      end

    throttling =
      case {sched, c[:throttled]} do
        {[], %{throttled_share_since_start: share}} when limited? and share >= 0.05 ->
          [
            {:warning,
             "the kernel has throttled the container in #{round(share * 100)}% of its CPU quota periods since it started#{throttle_text(c.throttled) |> String.replace(~r/^, and the kernel has throttled it in \d+% of its periods since it started/, "")}: for the rest of each such period the whole VM is stopped, so latency jumps by up to the period. The work needs more CPU than the quota of #{quota}"}
          ]

        _ ->
          []
      end

    dirty =
      if limited? and is_integer(c.dirty_cpu_schedulers_online) and
           c.dirty_cpu_schedulers_online > cpus,
         do: [
           {:info,
            "#{c.dirty_cpu_schedulers_online} dirty CPU schedulers online for a quota of #{quota} CPUs: dirty NIFs compete with the normal schedulers for it (+SDcpu #{cpus}:#{cpus})"}
         ],
         else: []

    busy =
      if limited? and c.busy_wait.sbwt != "none",
        do: [
          {:info,
           "the schedulers busy-wait before sleeping (+sbwt #{c.busy_wait.sbwt}), which spends the container's CPU quota spinning: with a CPU limit, +sbwt none +sbwtdcpu none +sbwtdio none give it back to work"}
        ],
        else: []

    memory =
      case r.memory do
        %{container_limit_bytes: limit} = m when is_integer(limit) ->
          used = max(m.vm_total_bytes, m[:os_resident_bytes] || 0)
          share = used / limit

          cond do
            share >= 0.9 ->
              [{:critical, memory_text(used, limit)}]

            share >= 0.75 ->
              [{:warning, memory_text(used, limit)}]

            true ->
              []
          end

        _ ->
          []
      end

    limits =
      for {name, %{share: share} = l} <- r.limits,
          name in [:ports, :ets_tables, :open_files],
          share >= 0.8 do
        {if(share >= 0.95, do: :critical, else: :warning),
         "#{l.used} of #{l.limit} #{String.replace(to_string(name), "_", " ")} in use (#{round(share * 100)}%): at the limit, opening one more fails#{if name == :open_files, do: " with emfile, sockets included", else: ""}"}
      end

    files =
      case r.limits[:open_files] do
        %{limit: soft} when is_integer(soft) and soft < 10_000 ->
          [
            {:info,
             "the OS allows #{soft} open files (ulimit -n), and every socket is one: a busy server needs more, and the VM's own port limit (#{info[:port_limit]}) is out of reach before it"}
          ]

        _ ->
          []
      end

    logging =
      if r.runtime.logger_level in [:debug, :all],
        do: [
          {:warning,
           "the logger's primary level is #{r.runtime.logger_level}: every debug message is built, formatted and handled, which costs in production; :info or :notice"}
        ],
        else: []

    jit =
      if r.runtime[:emulator] == :emu and
           String.contains?(r.runtime.architecture, ["x86_64", "aarch64", "arm64"]),
         do: [
           {:info,
            "this VM interprets BEAM code (emu_flavor emu) though its architecture has a JIT: code runs slower; an OTP built with the JIT (the default since OTP 24) is faster"}
         ],
         else: []

    gc =
      case info[:fullsweep_after] do
        {:fullsweep_after, n} when n < 65_535 ->
          [
            {:info,
             "the node's default fullsweep_after is #{n} (65535 by default): every process does a full garbage collection that often, costing CPU; usually set per process instead"}
          ]

        _ ->
          []
      end

    sched ++ throttling ++ dirty ++ busy ++ memory ++ limits ++ files ++ logging ++ jit ++ gc
  end

  defp throttle_text(%{throttled_share_since_start: share} = t) when share > 0 do
    last =
      case t[:last_second] do
        %{throttled: n, periods: p} = l when n > 0 ->
          "; in the last second, #{n} of #{p}#{if l[:throttled_ms], do: " (#{l.throttled_ms} ms of throttled time, summed over its CPUs)", else: ""}"

        _ ->
          ""
      end

    ", and the kernel has throttled it in #{round(share * 100)}% of its periods since it started#{last}"
  end

  defp throttle_text(_), do: ""

  defp memory_text(used, limit),
    do:
      "the node uses #{div(used, 1_000_000)} MB of the container's #{div(limit, 1_000_000)} MB memory limit (#{round(used * 100 / limit)}%): past it the kernel's OOM killer kills the VM outright, with no crash dump and nothing in its logs"

  defp rank(:critical), do: 0
  defp rank(:warning), do: 1
  defp rank(_), do: 2

  defp status(notes) do
    cond do
      Enum.any?(notes, &(elem(&1, 0) == :critical)) -> :critical
      Enum.any?(notes, &(elem(&1, 0) == :warning)) -> :warning
      true -> :ok
    end
  end

  defp put(map, _key, value) when value in [nil, false], do: map
  defp put(map, key, value), do: Map.put(map, key, value)

  defp interpretation do
    """
    How the VM is set up against what it runs on. cpu: schedulers online
    against the container's CPU quota (cgroup cpu.max, in CPUs per
    period) and the CPUs its affinity allows; more schedulers than the
    quota get the whole VM throttled each period it overruns, which shows
    as latency spikes of up to the period, not as high CPU. throttled:
    from the cgroup's cpu.stat, the share of periods the kernel stopped
    the container in since it started, and in the last second (its
    throttled time is summed over the CPUs the container ran on). busy_wait:
    the schedulers' spinning before they sleep (+sbwt), which a CPU quota
    pays for. memory: the VM's total and the OS's resident size against
    the container's memory limit; past it the OOM killer ends the VM with
    no crash dump. limits: processes, ports, atoms, ETS tables and open
    files (ulimit -n) in use against their limits. runtime: OTP, the
    emulator (jit or emu), code mode (interactive loads modules on first
    call), the logger's level. emulator_flags: the flags given on the
    command line or in ERL_FLAGS. Fixes go in vm.args (+S, +sbwt...), the
    container's limits, or the logger's config.
    """
  end
end
