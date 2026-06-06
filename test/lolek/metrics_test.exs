defmodule Lolek.MetricsTest do
  use ExUnit.Case, async: true

  setup do
    metrics_name = String.to_atom("#{__MODULE__}.#{System.unique_integer([:positive])}")
    %{metrics_name: metrics_name}
  end

  test "records message and rate limiter counters", %{metrics_name: metrics_name} do
    start_supervised!({Lolek.Metrics, name: metrics_name})

    Lolek.Metrics.record_message_result(:ok, name: metrics_name)
    Lolek.Metrics.record_message_result(:no_video_formats, name: metrics_name)
    Lolek.Metrics.record_chat_rate_limiter_result(true, name: metrics_name)
    Lolek.Metrics.record_chat_rate_limiter_result(false, name: metrics_name)

    metrics = Lolek.Metrics.prometheus_text(name: metrics_name)

    assert metrics =~ ~s(lolek_messages_total{result="ok"} 1)
    assert metrics =~ ~s(lolek_messages_total{result="no_video_formats"} 1)
    assert metrics =~ ~s(lolek_chat_rate_limiter_total{result="admitted"} 1)
    assert metrics =~ ~s(lolek_chat_rate_limiter_total{result="rejected"} 1)
  end

  test "records processing stage histograms and cache lookups", %{metrics_name: metrics_name} do
    start_supervised!({Lolek.Metrics, name: metrics_name})

    Lolek.Metrics.record_processing_stage("telegram send", {:ok, :sent}, 250, name: metrics_name)

    Lolek.Metrics.record_processing_stage("download", {:error, :no_video_formats}, 1_500,
      name: metrics_name
    )

    Lolek.Metrics.record_cache_lookup({:ok, {:ready_to_telegram, "/tmp/file.mp4"}},
      name: metrics_name
    )

    metrics = Lolek.Metrics.prometheus_text(name: metrics_name)

    assert metrics =~ ~s(lolek_processing_stage_total{result="ok",stage="telegram_send"} 1)

    assert metrics =~
             ~s(lolek_processing_stage_duration_seconds_bucket{le="0.25",result="ok",stage="telegram_send"} 1)

    assert metrics =~
             ~s(lolek_processing_stage_duration_seconds_count{result="no_video_formats",stage="download"} 1)

    assert metrics =~ ~s(lolek_cache_lookup_total{state="ready_to_telegram"} 1)
  end

  test "records active processing gauge", %{metrics_name: metrics_name} do
    start_supervised!({Lolek.Metrics, name: metrics_name})

    Lolek.Metrics.processing_started(name: metrics_name)
    Lolek.Metrics.processing_started(name: metrics_name)
    Lolek.Metrics.processing_finished(name: metrics_name)

    metrics = Lolek.Metrics.prometheus_text(name: metrics_name)

    assert metrics =~ "lolek_processing_active 1"
  end

  test "recording is a no-op when metrics process is not running", %{metrics_name: metrics_name} do
    Lolek.Metrics.record_message_result(:ok, name: metrics_name)

    assert Lolek.Metrics.prometheus_text(name: metrics_name) == ""
  end
end
