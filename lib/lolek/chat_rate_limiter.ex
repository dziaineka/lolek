defmodule Lolek.ChatRateLimiter do
  @moduledoc """
  Limits admitted media requests per Telegram chat over a rolling time window.
  """

  use GenServer

  @default_window_ms :timer.minutes(1)

  @type time_fun :: (-> integer())

  @type state :: %{
          limit: pos_integer(),
          window_ms: pos_integer(),
          attempts_by_chat: %{integer() => [integer()]},
          time_fun: time_fun()
        }

  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(opts \\ []) do
    name = Keyword.get(opts, :name, __MODULE__)
    GenServer.start_link(__MODULE__, opts, name: name)
  end

  @spec admit?(integer()) :: boolean()
  def admit?(chat_id), do: admit?(chat_id, [])

  @spec admit?(integer(), keyword()) :: boolean()
  def admit?(chat_id, opts) do
    server = Keyword.get(opts, :name, __MODULE__)
    GenServer.call(server, {:admit, chat_id})
  end

  @impl true
  @spec init(keyword()) :: {:ok, state()} | {:stop, term()}
  def init(opts) do
    limit =
      Keyword.get_lazy(opts, :limit, fn ->
        Application.fetch_env!(:lolek, :max_video_requests_per_chat_per_minute)
      end)

    window_ms = Keyword.get(opts, :window_ms, @default_window_ms)
    time_fun = Keyword.get(opts, :time_fun, fn -> System.monotonic_time(:millisecond) end)

    with :ok <- validate_positive_integer(:limit, limit),
         :ok <- validate_positive_integer(:window_ms, window_ms) do
      {:ok,
       %{
         limit: limit,
         window_ms: window_ms,
         attempts_by_chat: %{},
         time_fun: time_fun
       }}
    else
      {:error, reason} -> {:stop, reason}
    end
  end

  @impl true
  def handle_call({:admit, chat_id}, _from, state) do
    now = state.time_fun.()
    cutoff = now - state.window_ms
    attempts_by_chat = prune_attempts_by_chat(state.attempts_by_chat, cutoff)
    attempts = [now | Map.get(attempts_by_chat, chat_id, [])]

    {:reply, length(attempts) <= state.limit,
     %{state | attempts_by_chat: Map.put(attempts_by_chat, chat_id, attempts)}}
  end

  @spec prune_attempts_by_chat(%{integer() => [integer()]}, integer()) ::
          %{integer() => [integer()]}
  defp prune_attempts_by_chat(attempts_by_chat, cutoff) do
    attempts_by_chat
    |> Enum.reduce(%{}, fn {chat_id, attempts}, acc ->
      attempts = Enum.filter(attempts, &(&1 > cutoff))

      if attempts == [] do
        acc
      else
        Map.put(acc, chat_id, attempts)
      end
    end)
  end

  @spec validate_positive_integer(atom(), term()) :: :ok | {:error, term()}
  defp validate_positive_integer(_name, value) when is_integer(value) and value > 0 do
    :ok
  end

  defp validate_positive_integer(name, value) do
    {:error, {:invalid_limit, name, value}}
  end
end
