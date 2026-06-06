defmodule Lolek.Metrics do
  @moduledoc """
  Collects in-memory counters, gauges, and histograms for bot activity.
  """

  use GenServer

  @processing_duration_buckets [0.1, 0.25, 0.5, 1, 2.5, 5, 10, 30, 60, 120, 300, 600]

  @type labels :: %{String.t() => String.t()}
  @type metric_key :: {String.t(), labels()}
  @type histogram :: %{
          buckets: [number()],
          bucket_counts: %{number() => non_neg_integer()},
          count: non_neg_integer(),
          sum: number()
        }
  @type state :: %{
          counters: %{metric_key() => non_neg_integer()},
          gauges: %{metric_key() => number()},
          histograms: %{metric_key() => histogram()}
        }

  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(opts \\ []) do
    name = Keyword.get(opts, :name, __MODULE__)
    GenServer.start_link(__MODULE__, %{}, name: name)
  end

  @spec record_message_result(term()) :: :ok
  def record_message_result(result), do: record_message_result(result, [])

  @spec record_message_result(term(), keyword()) :: :ok
  def record_message_result(result, opts) do
    cast_if_started({:increment, "lolek_messages_total", %{result: result_label(result)}}, opts)
  end

  @spec record_chat_rate_limiter_result(boolean()) :: :ok
  def record_chat_rate_limiter_result(admitted?),
    do: record_chat_rate_limiter_result(admitted?, [])

  @spec record_chat_rate_limiter_result(boolean(), keyword()) :: :ok
  def record_chat_rate_limiter_result(admitted?, opts) do
    result =
      if admitted? do
        "admitted"
      else
        "rejected"
      end

    cast_if_started({:increment, "lolek_chat_rate_limiter_total", %{result: result}}, opts)
  end

  @spec record_cache_lookup(term()) :: :ok
  def record_cache_lookup(result), do: record_cache_lookup(result, [])

  @spec record_cache_lookup(term(), keyword()) :: :ok
  def record_cache_lookup({:ok, file_state}, opts) do
    labels = %{state: file_state_label(file_state)}
    cast_if_started({:increment, "lolek_cache_lookup_total", labels}, opts)
  end

  def record_cache_lookup(_result, _opts), do: :ok

  @spec record_processing_stage(String.t(), term(), number()) :: :ok
  def record_processing_stage(stage, result, elapsed_ms),
    do: record_processing_stage(stage, result, elapsed_ms, [])

  @spec record_processing_stage(String.t(), term(), number(), keyword()) :: :ok
  def record_processing_stage(stage, result, elapsed_ms, opts) do
    labels = %{
      result: result_label(result),
      stage: normalize_label_value(stage)
    }

    seconds = elapsed_ms / 1000

    cast_if_started(
      {:observe_processing_stage, labels, seconds},
      opts
    )
  end

  @spec processing_started() :: :ok
  def processing_started, do: processing_started([])

  @spec processing_started(keyword()) :: :ok
  def processing_started(opts),
    do: cast_if_started({:gauge_add, "lolek_processing_active", %{}, 1}, opts)

  @spec processing_finished() :: :ok
  def processing_finished, do: processing_finished([])

  @spec processing_finished(keyword()) :: :ok
  def processing_finished(opts),
    do: cast_if_started({:gauge_add, "lolek_processing_active", %{}, -1}, opts)

  @spec prometheus_text() :: String.t()
  def prometheus_text, do: prometheus_text([])

  @spec prometheus_text(keyword()) :: String.t()
  def prometheus_text(opts) do
    case server_pid(opts) do
      nil -> ""
      pid -> GenServer.call(pid, :prometheus_text)
    end
  end

  @impl true
  @spec init(map()) :: {:ok, state()}
  def init(_opts) do
    gauges = %{{"lolek_processing_active", %{}} => 0}

    {:ok, %{counters: %{}, gauges: gauges, histograms: %{}}}
  end

  @impl true
  def handle_cast({:increment, name, labels}, state) do
    {:noreply, increment_counter(state, name, stringify_labels(labels), 1)}
  end

  def handle_cast({:gauge_add, name, labels, value}, state) do
    key = {name, stringify_labels(labels)}
    value = max(Map.get(state.gauges, key, 0) + value, 0)
    {:noreply, %{state | gauges: Map.put(state.gauges, key, value)}}
  end

  def handle_cast({:observe_processing_stage, labels, value}, state) do
    labels = stringify_labels(labels)

    state =
      state
      |> increment_counter("lolek_processing_stage_total", labels, 1)
      |> observe_histogram(
        "lolek_processing_stage_duration_seconds",
        labels,
        value,
        @processing_duration_buckets
      )

    {:noreply, state}
  end

  @impl true
  def handle_call(:prometheus_text, _from, state) do
    {:reply, encode_prometheus(state), state}
  end

  @spec cast_if_started(term(), keyword()) :: :ok
  defp cast_if_started(message, opts) do
    case server_pid(opts) do
      nil -> :ok
      pid -> GenServer.cast(pid, message)
    end
  end

  @spec server_pid(keyword()) :: pid() | nil
  defp server_pid(opts) do
    opts
    |> Keyword.get(:name, __MODULE__)
    |> Process.whereis()
  end

  @spec increment_counter(state(), String.t(), labels(), pos_integer()) :: state()
  defp increment_counter(state, name, labels, increment) do
    key = {name, labels}
    counters = Map.update(state.counters, key, increment, &(&1 + increment))
    %{state | counters: counters}
  end

  @spec observe_histogram(state(), String.t(), labels(), number(), [number()]) :: state()
  defp observe_histogram(state, name, labels, value, buckets) do
    key = {name, labels}

    histogram =
      Map.get_lazy(state.histograms, key, fn ->
        %{
          buckets: buckets,
          bucket_counts: Map.new(buckets, &{&1, 0}),
          count: 0,
          sum: 0
        }
      end)

    bucket_counts =
      Enum.reduce(buckets, histogram.bucket_counts, fn bucket, counts ->
        if value <= bucket do
          Map.update!(counts, bucket, &(&1 + 1))
        else
          counts
        end
      end)

    histogram = %{
      histogram
      | bucket_counts: bucket_counts,
        count: histogram.count + 1,
        sum: histogram.sum + value
    }

    %{state | histograms: Map.put(state.histograms, key, histogram)}
  end

  @spec encode_prometheus(state()) :: String.t()
  defp encode_prometheus(state) do
    [
      encode_counters(state.counters),
      encode_gauges(state.gauges),
      encode_histograms(state.histograms)
    ]
    |> Enum.reject(&(&1 == ""))
    |> Enum.join("\n")
    |> Kernel.<>("\n")
  end

  @spec encode_counters(%{metric_key() => non_neg_integer()}) :: String.t()
  defp encode_counters(counters) do
    counters
    |> grouped_metric_lines("counter", &counter_lines/2)
    |> Enum.join("\n")
  end

  @spec encode_gauges(%{metric_key() => number()}) :: String.t()
  defp encode_gauges(gauges) do
    gauges
    |> grouped_metric_lines("gauge", &gauge_lines/2)
    |> Enum.join("\n")
  end

  @spec encode_histograms(%{metric_key() => histogram()}) :: String.t()
  defp encode_histograms(histograms) do
    histograms
    |> grouped_metric_lines("histogram", &histogram_lines/2)
    |> Enum.join("\n")
  end

  @spec grouped_metric_lines(map(), String.t(), (String.t(), [{labels(), term()}] -> [String.t()])) ::
          [String.t()]
  defp grouped_metric_lines(metrics, type, line_fun) do
    metrics
    |> Enum.group_by(fn {{name, _labels}, _value} -> name end, fn {{_name, labels}, value} ->
      {labels, value}
    end)
    |> Enum.sort_by(fn {name, _values} -> name end)
    |> Enum.flat_map(fn {name, values} ->
      [
        "# HELP #{name} Lolek metric #{name}.",
        "# TYPE #{name} #{type}"
        | line_fun.(name, Enum.sort_by(values, fn {labels, _value} -> labels end))
      ]
    end)
  end

  @spec counter_lines(String.t(), [{labels(), non_neg_integer()}]) :: [String.t()]
  defp counter_lines(name, values) do
    Enum.map(values, fn {labels, value} ->
      "#{name}#{encode_labels(labels)} #{value}"
    end)
  end

  @spec gauge_lines(String.t(), [{labels(), number()}]) :: [String.t()]
  defp gauge_lines(name, values) do
    Enum.map(values, fn {labels, value} ->
      "#{name}#{encode_labels(labels)} #{format_number(value)}"
    end)
  end

  @spec histogram_lines(String.t(), [{labels(), histogram()}]) :: [String.t()]
  defp histogram_lines(name, values) do
    Enum.flat_map(values, fn {labels, histogram} ->
      bucket_lines =
        Enum.map(histogram.buckets, fn bucket ->
          labels = Map.put(labels, "le", format_bucket(bucket))
          "#{name}_bucket#{encode_labels(labels)} #{Map.fetch!(histogram.bucket_counts, bucket)}"
        end)

      infinity_labels = Map.put(labels, "le", "+Inf")

      bucket_lines ++
        [
          "#{name}_bucket#{encode_labels(infinity_labels)} #{histogram.count}",
          "#{name}_sum#{encode_labels(labels)} #{format_number(histogram.sum)}",
          "#{name}_count#{encode_labels(labels)} #{histogram.count}"
        ]
    end)
  end

  @spec stringify_labels(map()) :: labels()
  defp stringify_labels(labels) do
    Map.new(labels, fn {key, value} -> {to_string(key), to_string(value)} end)
  end

  @spec encode_labels(labels()) :: String.t()
  defp encode_labels(labels) when map_size(labels) == 0, do: ""

  defp encode_labels(labels) do
    labels =
      labels
      |> Enum.sort_by(fn {key, _value} -> key end)
      |> Enum.map_join(",", fn {key, value} -> ~s(#{key}="#{escape_label_value(value)}") end)

    "{#{labels}}"
  end

  @spec escape_label_value(String.t()) :: String.t()
  defp escape_label_value(value) do
    value
    |> String.replace("\\", "\\\\")
    |> String.replace("\n", "\\n")
    |> String.replace("\"", "\\\"")
  end

  @spec format_bucket(number()) :: String.t()
  defp format_bucket(bucket), do: format_number(bucket)

  @spec format_number(number()) :: String.t()
  defp format_number(value) when is_integer(value), do: Integer.to_string(value)
  defp format_number(value), do: :erlang.float_to_binary(value, [:compact, decimals: 10])

  @spec file_state_label(term()) :: String.t()
  defp file_state_label({:new_file, _path}), do: "new_file"
  defp file_state_label({:downloaded, _path}), do: "downloaded"
  defp file_state_label({:compressed, _path}), do: "compressed"
  defp file_state_label({:ready_to_telegram, _path}), do: "ready_to_telegram"
  defp file_state_label({:sent_to_telegram_at_first, _path, _file_id}), do: "sent_to_telegram"
  defp file_state_label(_file_state), do: "unknown"

  @spec result_label(term()) :: String.t()
  defp result_label({:ok, _value}), do: "ok"
  defp result_label(:ok), do: "ok"
  defp result_label({:error, reason}), do: result_label(reason)
  defp result_label(:no_url), do: "no_url"
  defp result_label(:no_video_formats), do: "no_video_formats"
  defp result_label(:chat_rate_limited), do: "rate_limited"
  defp result_label(:rate_limited), do: "rate_limited"

  defp result_label(reason) when is_atom(reason),
    do: normalize_label_value(Atom.to_string(reason))

  defp result_label(_reason), do: "error"

  @spec normalize_label_value(String.t()) :: String.t()
  defp normalize_label_value(value) do
    value
    |> String.downcase()
    |> String.replace(~r/[^a-z0-9]+/, "_")
    |> String.trim("_")
    |> case do
      "" -> "unknown"
      label -> label
    end
  end
end
