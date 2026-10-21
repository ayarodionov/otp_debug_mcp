defmodule OtpDebugMcp.Format do
  @moduledoc ~S"""
  Terms from the target, with pids and ports as the target prints them.

  A pid from the target prints on our node as `#PID<39971.107.0>`: the
  first number is the index our node gave the target's node, which means
  nothing on the target, where the same process is `<0.107.0>`. Trace
  lines are formatted on the target and `remote_eval` takes the target's
  form, so every tool shows pids and ports that way, and an agent can
  match them up across tools.

  Pids and ports of any other node (ours, or a node in the target's
  cluster that we aren't connected to) are shown with their node name,
  e.g. `<other@host.107.0>`, so they can't be mistaken for the target's.

  Terms from a node that runs only Erlang are shown in Erlang syntax
  (`price_cache`, `#{k => v}`, `"text"`), from one that runs Elixir in
  Elixir syntax (`:price_cache`, `%{k: v}`).
  """

  alias OtpDebugMcp.Target

  defmodule Printed do
    @moduledoc false
    # Inspects as its text, unquoted, so a localized pid sits in a term
    # the way a pid would.
    defstruct [:text]

    defimpl Inspect do
      def inspect(%{text: text}, _opts), do: text
    end
  end

  @doc """
  Like `Kernel.inspect/2`, with the target's pids and ports in its own
  form, and in Erlang syntax if the target runs only Erlang (`:pretty`
  spreads it over lines; `:limit` caps its depth there).
  """
  def inspect(term, opts \\ []) do
    node = Target.connected_node()
    localized = localize(term, node)

    case Target.syntax(node) do
      :erlang -> erlang_syntax(localized, opts)
      _ -> Kernel.inspect(localized, opts)
    end
  end

  # Erlang's printer knows nothing of Printed, so localized pids and ports
  # stand in as placeholder atoms while it prints, then are swapped back.
  defp erlang_syntax(term, opts) do
    {term, {_by_text, by_name}} = placeholders(term, {%{}, %{}})

    depth =
      case Keyword.get(opts, :limit, 50) do
        :infinity -> -1
        n -> n
      end

    format = if opts[:pretty], do: ~c"~tP", else: ~c"~9999tP"
    text = format |> :io_lib.format([term, depth]) |> IO.chardata_to_string()
    Regex.replace(~r/otpdbg_p\d+/, text, &Map.get(by_name, &1, &1))
  end

  defp placeholders(%Printed{text: text}, {by_text, by_name} = acc) do
    case by_text do
      %{^text => name} ->
        {String.to_atom(name), acc}

      _ ->
        name = "otpdbg_p#{map_size(by_name)}"
        {String.to_atom(name), {Map.put(by_text, text, name), Map.put(by_name, name, text)}}
    end
  end

  defp placeholders([head | tail], acc) do
    {head, acc} = placeholders(head, acc)
    {tail, acc} = placeholders(tail, acc)
    {[head | tail], acc}
  end

  defp placeholders(tuple, acc) when is_tuple(tuple) do
    {list, acc} = placeholders(Tuple.to_list(tuple), acc)
    {List.to_tuple(list), acc}
  end

  defp placeholders(map, acc) when is_map(map) do
    {pairs, acc} =
      Enum.map_reduce(:maps.to_list(map), acc, fn {k, v}, acc ->
        {k, acc} = placeholders(k, acc)
        {v, acc} = placeholders(v, acc)
        {{k, v}, acc}
      end)

    {:maps.from_list(pairs), acc}
  end

  defp placeholders(other, acc), do: {other, acc}

  @doc """
  `io_lib:format(Format, Args, Opts)` evaluated on the target, so pids and
  ports print in its form. Falls back to formatting here if the target
  can't be reached.
  """
  def erlang(format, args, opts \\ []) do
    chars =
      case Target.rpc(:io_lib, :format, [format, args, opts]) do
        {:ok, chars} -> chars
        {:error, _} -> :io_lib.format(format, args, opts)
      end

    IO.chardata_to_string(chars)
  end

  defp localize(pid, target) when is_pid(pid), do: printed(pid, :erlang.pid_to_list(pid), target)

  defp localize(port, target) when is_port(port),
    do: printed(port, :erlang.port_to_list(port), target)

  defp localize(%Printed{} = printed, _target), do: printed

  defp localize(list, target) when is_list(list), do: localize_list(list, target)

  defp localize(tuple, target) when is_tuple(tuple) do
    tuple |> Tuple.to_list() |> localize_list(target) |> List.to_tuple()
  end

  # Through the list form, which keeps a struct's __struct__ key.
  defp localize(map, target) when is_map(map) do
    map
    |> :maps.to_list()
    |> Enum.map(fn {k, v} -> {localize(k, target), localize(v, target)} end)
    |> :maps.from_list()
  end

  defp localize(other, _target), do: other

  # Lists may be improper.
  defp localize_list([head | tail], target),
    do: [localize(head, target) | localize_list(tail, target)]

  defp localize_list([], _target), do: []
  defp localize_list(tail, target), do: localize(tail, target)

  # "<39971.107.0>" -> "<0.107.0>"; "#Port<39971.5>" -> "#Port<0.5>".
  defp printed(id, printed, target) do
    [prefix, rest] = printed |> to_string() |> String.split("<", parts: 2)
    [_index, rest] = String.split(rest, ".", parts: 2)
    owner = if node(id) == target, do: "0", else: Atom.to_string(node(id))
    %Printed{text: "#{prefix}<#{owner}.#{rest}"}
  end
end
