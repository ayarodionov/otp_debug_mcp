defmodule OtpDebugMcp.CodeLoad do
  @moduledoc """
  Hot-loads a module's object code onto the target, the way `nl/1` in a
  shell does, to try a fix on a live node. `OtpDebugMcp.Tools.LoadModule`
  asks the user before every load.

  The node's own files aren't touched, so the new code lasts until the
  node restarts or the module is reverted, which reloads the version on the
  node's code path. Nothing is purged by force: if processes still run old
  code left by an earlier load, the load is refused rather than killing
  them.
  """

  alias OtpDebugMcp.Checks

  @doc """
  Reads a `.beam` file on this machine. Returns its module, the md5 the
  target will report for it once loaded, and the object code.
  """
  def read_beam(path) do
    path = Path.expand(path)

    with {:ok, bin} <- read(path),
         {:ok, {mod, md5}} <- md5(bin, path) do
      {:ok, %{module: mod, md5: md5, file: path, binary: bin}}
    end
  end

  defp read(path) do
    case File.read(path) do
      {:ok, bin} -> {:ok, bin}
      {:error, reason} -> {:error, "can't read #{path}: #{:file.format_error(reason)}"}
    end
  end

  defp md5(bin, path) do
    case :beam_lib.md5(bin) do
      {:ok, {mod, md5}} -> {:ok, {mod, md5}}
      {:error, :beam_lib, _} -> {:error, "#{path} isn't a .beam file"}
    end
  end

  @plan ~S"""
  Loaded = case code:is_loaded(Mod) of
             {file, F} -> {F, erlang:get_module_info(Mod, md5)};
             false -> not_loaded
           end,
  OnDisk = case code:get_object_code(Mod) of
             {Mod, Bin, File} ->
               {ok, {Mod, Md5}} = beam_lib:md5(Bin),
               {File, Md5};
             error -> none
           end,
  Running = [P || P <- processes(),
                  case erlang:process_info(P, current_function) of
                    {current_function, {Mod, _, _}} -> true;
                    _ -> false
                  end],
  #{loaded => Loaded, on_disk => OnDisk, sticky => code:is_sticky(Mod),
    running => {length(Running), lists:sublist(Running, 5)},
    otp_release => erlang:system_info(otp_release)}.
  """

  @doc """
  What the target has of `mod`: the loaded version and the one on its code
  path (each `{file, md5}`), whether it's sticky, and the processes
  executing it now.
  """
  def plan(mod), do: Checks.remote_eval(@plan, Mod: mod)

  # Source is the code to load, {File, Bin}, or on_disk for the version
  # on the node's code path. Expected is the md5 the user approved: the
  # code is checked against it on the target, just before it's loaded.
  @load ~S"""
  OldCodeUsers = fun() -> [P || P <- processes(), erlang:check_process_code(P, Mod)] end,
  Code = case Source of
           on_disk -> case code:get_object_code(Mod) of
                        {Mod, B, F} -> {F, B};
                        error -> none
                      end;
           {_, _} -> Source
         end,
  case Code of
    none -> {error, not_on_code_path};
    {File, Bin} ->
      case {beam_lib:md5(Bin), code:is_sticky(Mod)} of
        {{ok, {Mod, Expected}}, false} ->
          case code:soft_purge(Mod) of
            false -> {error, {old_code_in_use, lists:sublist(OldCodeUsers(), 5)}};
            true ->
              case code:load_binary(Mod, File, Bin) of
                {module, Mod} -> {ok, File, lists:sublist(OldCodeUsers(), 5), length(OldCodeUsers())};
                {error, Reason} -> {error, Reason}
              end
          end;
        {_, true} -> {error, sticky};
        _ -> {error, changed}
      end
  end.
  """

  @doc """
  Loads `source` (`{file, binary}`, or `:on_disk` to revert) as `mod` on
  the target, if its md5 is still `expected`.
  """
  def load(mod, source, expected) do
    source =
      case source do
        {file, bin} -> {String.to_charlist(file), bin}
        :on_disk -> :on_disk
      end

    case Checks.remote_eval(@load, Mod: mod, Source: source, Expected: expected) do
      {:ok, {:ok, file, old_users, n}} ->
        {:ok, %{file: to_string(file), old_code_users: {n, old_users}}}

      {:ok, {:error, reason}} ->
        {:error, reason}

      {:error, _} = err ->
        err
    end
  end

  @doc """
  Where the target says a loaded module came from: a file, or nothing for
  code compiled in memory (an .exs script, `Code.compile_string/1`).
  """
  def file_name([]), do: "no file: compiled in memory"
  def file_name(file), do: to_string(file)

  @doc "An md5 as the target reports it, in hex."
  def hex(md5), do: Base.encode16(md5, case: :lower)
end
