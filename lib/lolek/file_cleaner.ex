defmodule Lolek.FileCleaner do
  @moduledoc """
  This module is responsible for cleaning the downloads directory.
  """
  use GenServer
  require Logger

  @spec start_link() :: GenServer.on_start()
  def start_link do
    GenServer.start_link(__MODULE__, %{}, name: __MODULE__)
  end

  @spec child_spec(any()) :: Supervisor.child_spec()
  def child_spec(_args) do
    %{
      id: __MODULE__,
      start: {__MODULE__, :start_link, []}
    }
  end

  @impl true
  def init(state) do
    :timer.send_interval(60 * 60 * 1000, __MODULE__, :cleanup)
    {:ok, state}
  end

  @impl true
  def handle_info(:cleanup, state) do
    cleanup_downloads_directory()
    {:noreply, state}
  end

  @spec cleanup_downloads_directory() :: :ok
  defp cleanup_downloads_directory do
    downloads_dir = "/path/to/downloads"
    # 5 GB in bytes
    max_size = 5 * 1024 * 1024 * 1024

    case File.stat(downloads_dir) do
      {:ok, %File.Stat{size: size}} when size > max_size ->
        Logger.info("Cleaning downloads directory...")
        cleanup_oldest_files(downloads_dir, max_size - size)
        :ok

      _ ->
        Logger.info("Downloads directory is within the size limit.")
    end
  end

  @spec cleanup_oldest_files(String.t(), integer()) :: integer()
  defp cleanup_oldest_files(dir, space_to_free) do
    files =
      dir
      |> File.ls!()
      |> Enum.map(&{&1, File.stat!(Path.join(dir, &1)).ctime})

    files
    |> Enum.sort_by(&elem(&1, 1))
    |> Enum.reduce(space_to_free, fn {file, _}, acc ->
      file_path = Path.join(dir, file)
      file_size = File.stat!(file_path).size

      case File.rm(file_path) do
        :ok ->
          Logger.info("Removed #{file} (#{file_size} bytes)")
          acc - file_size

        _ ->
          Logger.warning("Failed to remove #{file}")
          acc
      end
    end)
  end
end
