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

  @spec cleanup_now() :: :ok
  def cleanup_now do
    GenServer.call(__MODULE__, :cleanup_now)
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

  @impl true
  def handle_call(:cleanup_now, _from, state) do
    cleanup_downloads_directory()
    {:reply, :ok, state}
  end

  @spec cleanup_downloads_directory() :: :ok
  def cleanup_downloads_directory do
    downloads_dir = Application.fetch_env!(:lolek, :download_path)
    max_size = Application.fetch_env!(:lolek, :max_download_dir_size)

    cleanup_downloads_directory(downloads_dir, max_size)
  end

  @spec cleanup_downloads_directory(String.t(), non_neg_integer()) :: :ok
  def cleanup_downloads_directory(downloads_dir, max_size) do
    entries = cache_entries(downloads_dir)
    total_size = entries |> Enum.map(& &1.size) |> Enum.sum()

    if total_size > max_size do
      Logger.info("Cleaning downloads directory...")
      cleanup_oldest_entries(entries, total_size - max_size)
    else
      Logger.info("Downloads directory is within the size limit.")
    end

    :ok
  end

  @spec cache_entries(String.t()) :: [
          %{
            path: String.t(),
            name: String.t(),
            size: non_neg_integer(),
            mtime: File.calendar_time()
          }
        ]
  defp cache_entries(downloads_dir) do
    case File.ls(downloads_dir) do
      {:ok, entries} ->
        Enum.map(entries, fn name ->
          path = Path.join(downloads_dir, name)

          %{
            path: path,
            name: name,
            size: path_size(path),
            mtime: path_mtime(path)
          }
        end)

      {:error, :enoent} ->
        []

      {:error, reason} ->
        Logger.warning("Could not list downloads directory #{downloads_dir}: #{inspect(reason)}")
        []
    end
  end

  @spec cleanup_oldest_entries([map()], integer()) :: :ok
  defp cleanup_oldest_entries(entries, space_to_free) do
    _remaining =
      entries
      |> Enum.sort_by(& &1.mtime)
      |> Enum.reduce_while(space_to_free, fn entry, remaining ->
        if remaining <= 0 do
          {:halt, remaining}
        else
          process_cleanup_entry(entry, remaining)
        end
      end)

    :ok
  end

  @spec process_cleanup_entry(map(), integer()) ::
          {:cont, integer()} | {:halt, integer()}
  defp process_cleanup_entry(entry, remaining) do
    case File.rm_rf(entry.path) do
      {:ok, _removed} ->
        Logger.info("Removed #{entry.name} (#{entry.size} bytes)")
        {:cont, remaining - entry.size}

      {:error, failed_path, reason} ->
        Logger.warning("Failed to remove #{failed_path}: #{inspect(reason)}")
        {:cont, remaining}
    end
  end

  @spec path_size(String.t()) :: non_neg_integer()
  defp path_size(path) do
    case File.lstat(path) do
      {:ok, %File.Stat{type: :directory}} ->
        path
        |> list_child_paths()
        |> Enum.map(&path_size/1)
        |> Enum.sum()

      {:ok, %File.Stat{size: size}} ->
        size

      {:error, _reason} ->
        0
    end
  end

  @spec list_child_paths(String.t()) :: [String.t()]
  defp list_child_paths(path) do
    case File.ls(path) do
      {:ok, children} -> Enum.map(children, &Path.join(path, &1))
      {:error, _reason} -> []
    end
  end

  @spec path_mtime(String.t()) :: File.calendar_time()
  defp path_mtime(path) do
    case File.lstat(path) do
      {:ok, %File.Stat{mtime: mtime}} -> mtime
      {:error, _reason} -> {{0, 1, 1}, {0, 0, 0}}
    end
  end
end
