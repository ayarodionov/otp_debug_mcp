defmodule OtpDebugMcp.PgServer do
  @moduledoc """
  A throwaway PostgreSQL server for the Postgrex tests: a fresh cluster in
  a temporary directory, on a free port, trusting local connections,
  stopped and removed when the test ends. It needs PostgreSQL's binaries
  (initdb, pg_ctl), on the PATH or where Debian and Ubuntu put them;
  without them, the tests tagged :postgres are skipped.
  """

  @doc "The directory of PostgreSQL's binaries, or nil."
  def bindir do
    case System.find_executable("initdb") do
      nil ->
        "/usr/lib/postgresql/*/bin/initdb"
        |> Path.wildcard()
        |> Enum.sort()
        |> List.last()
        |> then(&(&1 && Path.dirname(&1)))

      initdb ->
        Path.dirname(initdb)
    end
  end

  @doc "Start a server: its connection options (database postgres, user postgres), and its data directory."
  def start do
    bin = bindir() || raise "no PostgreSQL binaries"
    dir = Path.join(System.tmp_dir!(), "otpdbg_pg_#{System.unique_integer([:positive])}")
    port = free_port()

    {_, 0} =
      System.cmd(
        Path.join(bin, "initdb"),
        ["-D", dir, "-U", "postgres", "-A", "trust", "--no-sync"],
        stderr_to_stdout: true
      )

    # The socket in the data directory: /tmp may not be writable.
    {_, 0} =
      System.cmd(
        Path.join(bin, "pg_ctl"),
        [
          "-D",
          dir,
          "-w",
          "-l",
          Path.join(dir, "log"),
          "-o",
          "-p #{port} -k #{dir} -c listen_addresses=127.0.0.1 -c fsync=off",
          "start"
        ],
        stderr_to_stdout: true
      )

    ExUnit.Callbacks.on_exit(fn ->
      System.cmd(Path.join(bin, "pg_ctl"), ["-D", dir, "-m", "immediate", "stop"],
        stderr_to_stdout: true
      )

      File.rm_rf!(dir)
    end)

    {[hostname: "127.0.0.1", port: port, username: "postgres", database: "postgres"], dir}
  end

  @doc "Stop the server in `dir` at once, as if it crashed."
  def stop(dir) do
    {_, 0} =
      System.cmd(Path.join(bindir(), "pg_ctl"), ["-D", dir, "-m", "immediate", "stop"],
        stderr_to_stdout: true
      )

    :ok
  end

  defp free_port do
    {:ok, socket} = :gen_tcp.listen(0, [])
    {:ok, port} = :inet.port(socket)
    :gen_tcp.close(socket)
    port
  end
end
