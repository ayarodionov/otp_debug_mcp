defmodule OtpDebugMcp.Ets do
  @moduledoc """
  One ETS table in detail: its settings and owner, its first rows, and
  what a bounded scan of its rows finds: the average row, the largest
  rows, and for a bag the keys with the most rows.

  The ets_tables check names the largest tables; this says what's in one.
  Rows are read on the target with `ets:select/3` in chunks, so a big
  table is never copied whole, and a row is sent here only if it's small;
  a large one is described by its key and size. A private table can only
  be read by its owner, so for one only its settings are shown.
  """

  alias OtpDebugMcp.{Checks, Format}

  # Rows up to this many words come back whole; larger ones by key and size.
  @max_row_words 5_000

  # The table: a named table's, or the largest of those with that name (a
  # table needn't be named_table to have a name, and names needn't be
  # unique). Then its info and, if this process may read it, its first
  # rows and a scan of up to Scan rows in chunks: the rows' sizes, the
  # largest, and for a bag the most repeated keys.
  @inspect ~S"""
  Names = [N || B <- Names0, N <- [catch binary_to_existing_atom(B, utf8)], is_atom(N)],
  %% ets:all() gives a named table by its name, ets:whereis/1 by its id:
  %% the id is the same table's either way.
  Candidates = lists:usort([Id || N <- Names,
                                  T <- [ets:whereis(N) | ets:all()],
                                  T =/= undefined,
                                  ets:info(T, name) =:= N,
                                  Id <- [ets:info(T, id)], Id =/= undefined]),
  case lists:reverse(lists:sort([{M, T} || T <- Candidates, M <- [ets:info(T, memory)], M =/= undefined])) of
    [] ->
      none;
    [{_, Tab} | _] = Found ->
      Info = ets:info(Tab),
      Owner = proplists:get_value(owner, Info),
      OwnerInfo = catch erlang:process_info(Owner, [registered_name, current_function]),
      Words = erlang:system_info(wordsize),
      KeyPos = proplists:get_value(keypos, Info),
      Small = fun(Row) ->
        case erts_debug:flat_size(Row) of
          W when W =< MaxRowWords -> {row, Row};
          W -> {large, element(KeyPos, Row), W * Words}
        end
      end,
      Readable = proplists:get_value(protection, Info) =/= private,
      Contents = case Readable of
        false ->
          private;
        true ->
          All = [{'_', [], ['$_']}],
          First = case ets:select(Tab, All, Rows) of
            {L, _} -> [Small(R) || R <- L];
            '$end_of_table' -> []
          end,
          Bag = lists:member(proplists:get_value(type, Info), [bag, duplicate_bag]),
          Step = fun(Batch, {Seen, Bytes, Top, Keys}) ->
            lists:foldl(fun(R, {S, B, T, K}) ->
              Size = erts_debug:flat_size(R) * Words,
              Key = element(KeyPos, R),
              T2 = lists:sublist(lists:reverse(lists:sort([{Size, Key} | T])), 5),
              K2 = case Bag of true -> maps:update_with(Key, fun(C) -> C + 1 end, 1, K); false -> K end,
              {S + 1, B + Size, T2, K2}
            end, {Seen, Bytes, Top, Keys}, Batch)
          end,
          Scan = fun Loop({Batch, Cont}, Acc = {Seen, _, _, _}) when Seen < ScanMax ->
                       Acc2 = Step(Batch, Acc),
                       case Cont of
                         '$end_of_table' -> {Acc2, complete};
                         _ -> Loop(ets:select(Cont), Acc2)
                       end;
                     Loop('$end_of_table', Acc) -> {Acc, complete};
                     Loop(_, Acc) -> {Acc, partial}
                 end,
          {{Seen, Bytes, Top, Keys}, Done} = Scan(ets:select(Tab, All, Chunk), {0, 0, [], #{}}),
          Largest = [{Key, Size, case ets:lookup(Tab, Key) of
                                   [R | _] -> Small(R);
                                   [] -> gone
                                 end} || {Size, Key} <- Top],
          HotKeys = lists:sublist(lists:reverse(lists:keysort(2, maps:to_list(Keys))), 5),
          {First, Seen, Bytes, Done, Largest, [{K, C} || {K, C} <- HotKeys, C > 1]}
      end,
      {length(Found), Info, OwnerInfo, Words, Contents}
  end.
  """

  @doc """
  The table named `name` (as printed: `my_table`, `:my_table` or
  `MyApp.Cache`): its settings, its first `rows` rows, and a scan of up to
  `scan` rows.
  """
  def inspect(name, rows, scan) do
    bindings = [
      Names0: names(name),
      Rows: rows,
      ScanMax: scan,
      Chunk: min(500, scan),
      MaxRowWords: @max_row_words
    ]

    case Checks.remote_eval(@inspect, bindings) do
      {:ok, :none} ->
        {:error,
         "no ETS table named #{name} on the target (the ets_tables check lists the largest)"}

      {:ok, {found, info, owner_info, words, contents}} ->
        {:ok, report(name, found, info, owner_info, words, contents)}

      err ->
        err
    end
  end

  # The atom's text as Erlang and Elixir print it, without creating it here.
  defp names(name) do
    name = String.trim(name)
    bare = name |> String.trim_leading(":") |> String.trim("'") |> String.trim("\"")
    Enum.uniq([bare, "Elixir." <> bare])
  end

  defp report(name, found, info, owner_info, words, contents) do
    owner = info[:owner]

    %{
      table: Format.inspect(info[:name]),
      type: info[:type],
      protection: info[:protection],
      rows: info[:size],
      memory_bytes: info[:memory] * words,
      keypos: info[:keypos],
      named_table: info[:named_table],
      read_concurrency: info[:read_concurrency],
      write_concurrency: info[:write_concurrency],
      compressed: info[:compressed],
      owner: owner_of(owner, owner_info),
      heir: Format.inspect(info[:heir])
    }
    |> put(:note, found > 1 && "#{found} tables are named #{name}; this is the largest")
    |> Map.merge(contents(contents, info[:size]))
    |> Map.put(:interpretation, interpretation())
  end

  defp owner_of(pid, info) when is_list(info) do
    %{pid: Format.inspect(pid), current_function: Format.inspect(info[:current_function])}
    |> put(
      :name,
      info[:registered_name] not in [nil, []] && Format.inspect(info[:registered_name])
    )
  end

  defp owner_of(pid, _), do: %{pid: Format.inspect(pid), alive: false}

  defp contents(:private, _rows) do
    %{
      readable: false,
      why: "private: only its owner can read it, so its rows can't be shown"
    }
  end

  # The largest rows only if they stand out: at least twice the average.
  defp contents({first, seen, bytes, done, largest, hot_keys}, rows) do
    average = if seen > 0, do: div(bytes, seen), else: 0
    standing_out = for {_, size, _} = l <- largest, size >= 2 * average, do: l

    %{
      first_rows: Enum.map(first, &row/1),
      scanned:
        %{rows: seen, of: rows, complete: done == :complete, average_row_bytes: average}
        |> put(
          :largest,
          standing_out != [] &&
            for {key, size, r} <- standing_out do
              %{key: short(key), bytes: size} |> put(:row, r != :gone && row(r))
            end
        )
        |> put(:largest_row_bytes, standing_out == [] && largest != [] && elem(hd(largest), 1))
    }
    |> put(
      :most_rows_per_key,
      hot_keys != [] && for({k, n} <- hot_keys, do: %{key: short(k), rows: n})
    )
  end

  defp row({:row, r}), do: short(r)
  defp row({:large, key, bytes}), do: "(a #{bytes}-byte row; its key is #{short(key)})"

  defp short(term) do
    text = Format.inspect(term, limit: 20, printable_limit: 200)
    if byte_size(text) > 600, do: binary_part(text, 0, 600) <> "…", else: text
  end

  defp put(map, _key, value) when value in [nil, false], do: map
  defp put(map, key, value), do: Map.put(map, key, value)

  defp interpretation do
    """
    rows and memory_bytes are the whole table; first_rows are the first
    few in its own order (key order for an ordered_set), scanned the rows
    read to size them, at most the scan limit: largest lists those at
    least twice average_row_bytes, and when none is, largest_row_bytes
    says how big the biggest is. What to look for: a table
    growing in snapshot diffs whose keys come from input (sessions, request
    ids) and are never deleted, a cache with no eviction; a few rows far
    larger than average_row_bytes (a whole list or map stored under one
    key, copied out in full on every lookup: split it into rows); for a
    bag, most_rows_per_key, a hot key whose rows every lookup returns.
    The owner is the process the table dies with, unless heir is set.
    Rows can hold personal data or secrets: they go to the AI provider
    like any tool output.
    """
  end
end
