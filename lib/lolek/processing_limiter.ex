defmodule Lolek.ProcessingLimiter do
  @moduledoc """
  Limits concurrent media processing globally and per chat.
  """

  use GenServer

  @type process_result :: {:ok, term()} | {:error, term()}

  @type waiter :: %{
          from: GenServer.from(),
          pid: pid(),
          chat_id: integer(),
          monitor_ref: reference()
        }

  @type state :: %{
          global_limit: pos_integer(),
          per_chat_limit: pos_integer(),
          active: %{reference() => {pid(), integer()}},
          active_by_chat: %{integer() => non_neg_integer()},
          waiting: [waiter()]
        }

  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(opts \\ []) do
    name = Keyword.get(opts, :name, __MODULE__)
    GenServer.start_link(__MODULE__, opts, name: name)
  end

  @spec with_limit(integer(), (-> process_result())) :: process_result()
  def with_limit(chat_id, fun) when is_function(fun, 0) do
    with_limit(chat_id, fun, [])
  end

  @spec with_limit(integer(), (-> process_result()), keyword()) :: process_result()
  def with_limit(chat_id, fun, opts) when is_function(fun, 0) do
    server = Keyword.get(opts, :name, __MODULE__)
    timeout = Keyword.get(opts, :timeout, :infinity)

    {:ok, token} = GenServer.call(server, {:acquire, self(), chat_id}, timeout)
    Lolek.Metrics.processing_started()

    try do
      fun.()
    after
      Lolek.Metrics.processing_finished()
      GenServer.cast(server, {:release, token})
    end
  end

  @impl true
  @spec init(keyword()) :: {:ok, state()} | {:stop, term()}
  def init(opts) do
    global_limit =
      Keyword.get_lazy(opts, :global_limit, fn ->
        Application.fetch_env!(:lolek, :max_concurrent_downloads)
      end)

    per_chat_limit =
      Keyword.get_lazy(opts, :per_chat_limit, fn ->
        Application.fetch_env!(:lolek, :max_concurrent_downloads_per_chat)
      end)

    with :ok <- validate_positive_limit(:global_limit, global_limit),
         :ok <- validate_positive_limit(:per_chat_limit, per_chat_limit),
         :ok <- validate_per_chat_limit(global_limit, per_chat_limit) do
      {:ok,
       %{
         global_limit: global_limit,
         per_chat_limit: per_chat_limit,
         active: %{},
         active_by_chat: %{},
         waiting: []
       }}
    else
      {:error, reason} -> {:stop, reason}
    end
  end

  @impl true
  def handle_call({:acquire, pid, chat_id}, from, state) do
    if capacity_available?(state, chat_id) do
      {token, state} = grant(pid, chat_id, state)
      {:reply, {:ok, token}, state}
    else
      monitor_ref = Process.monitor(pid)
      waiter = %{from: from, pid: pid, chat_id: chat_id, monitor_ref: monitor_ref}
      {:noreply, %{state | waiting: state.waiting ++ [waiter]}}
    end
  end

  @impl true
  def handle_cast({:release, token}, state) do
    state =
      token
      |> release_active(state)
      |> grant_waiting()

    {:noreply, state}
  end

  @impl true
  def handle_info({:DOWN, monitor_ref, :process, _pid, _reason}, state) do
    state =
      state
      |> remove_waiter(monitor_ref)
      |> then(&release_active(monitor_ref, &1))
      |> grant_waiting()

    {:noreply, state}
  end

  @spec grant_waiting(state()) :: state()
  defp grant_waiting(state) do
    {state, waiting} =
      Enum.reduce(state.waiting, {%{state | waiting: []}, []}, fn waiter, {state, waiting} ->
        if capacity_available?(state, waiter.chat_id) do
          state = grant_waiter(waiter, state)
          {state, waiting}
        else
          {state, waiting ++ [waiter]}
        end
      end)

    %{state | waiting: waiting}
  end

  @spec grant_waiter(waiter(), state()) :: state()
  defp grant_waiter(waiter, state) do
    state = activate(waiter.monitor_ref, waiter.pid, waiter.chat_id, state)
    GenServer.reply(waiter.from, {:ok, waiter.monitor_ref})
    state
  end

  @spec grant(pid(), integer(), state()) :: {reference(), state()}
  defp grant(pid, chat_id, state) do
    monitor_ref = Process.monitor(pid)
    {monitor_ref, activate(monitor_ref, pid, chat_id, state)}
  end

  @spec activate(reference(), pid(), integer(), state()) :: state()
  defp activate(monitor_ref, pid, chat_id, state) do
    %{
      state
      | active: Map.put(state.active, monitor_ref, {pid, chat_id}),
        active_by_chat: Map.update(state.active_by_chat, chat_id, 1, &(&1 + 1))
    }
  end

  @spec release_active(reference(), state()) :: state()
  defp release_active(token, state) do
    case Map.pop(state.active, token) do
      {{_pid, chat_id}, active} ->
        Process.demonitor(token, [:flush])

        %{
          state
          | active: active,
            active_by_chat: decrement_chat_count(state.active_by_chat, chat_id)
        }

      {nil, _active} ->
        state
    end
  end

  @spec remove_waiter(state(), reference()) :: state()
  defp remove_waiter(state, monitor_ref) do
    %{state | waiting: Enum.reject(state.waiting, &(&1.monitor_ref == monitor_ref))}
  end

  @spec capacity_available?(state(), integer()) :: boolean()
  defp capacity_available?(state, chat_id) do
    map_size(state.active) < state.global_limit and
      Map.get(state.active_by_chat, chat_id, 0) < state.per_chat_limit
  end

  @spec validate_positive_limit(atom(), term()) :: :ok | {:error, term()}
  defp validate_positive_limit(_name, value) when is_integer(value) and value > 0 do
    :ok
  end

  defp validate_positive_limit(name, value) do
    {:error, {:invalid_limit, name, value}}
  end

  @spec validate_per_chat_limit(pos_integer(), pos_integer()) :: :ok | {:error, term()}
  defp validate_per_chat_limit(global_limit, per_chat_limit)
       when per_chat_limit <= global_limit do
    :ok
  end

  defp validate_per_chat_limit(global_limit, per_chat_limit) do
    {:error, {:per_chat_limit_exceeds_global_limit, per_chat_limit, global_limit}}
  end

  @spec decrement_chat_count(%{integer() => non_neg_integer()}, integer()) ::
          %{integer() => non_neg_integer()}
  defp decrement_chat_count(active_by_chat, chat_id) do
    case Map.fetch(active_by_chat, chat_id) do
      {:ok, count} when count <= 1 -> Map.delete(active_by_chat, chat_id)
      {:ok, count} -> Map.put(active_by_chat, chat_id, count - 1)
      :error -> active_by_chat
    end
  end
end
