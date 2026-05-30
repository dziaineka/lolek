defmodule Lolek.TelegramLog do
  @moduledoc """
  Formats Telegram HTTP client logs without leaking bot credentials.
  """

  @spec format_request(Tesla.Env.t(), Tesla.Env.result(), integer()) :: IO.chardata()
  def format_request(request, response, time) do
    [
      request.method |> to_string() |> String.upcase(),
      " ",
      sanitize_url(request.url),
      " -> ",
      format_status(response),
      " (",
      :io_lib.format("~.3f", [time / 1000]),
      " ms)"
    ]
  end

  @spec sanitize_url(String.t()) :: String.t()
  def sanitize_url(url) do
    url
    |> URI.parse()
    |> sanitized_url_parts(url)
    |> IO.iodata_to_binary()
  end

  @spec sanitized_url_parts(URI.t(), String.t()) :: IO.chardata()
  defp sanitized_url_parts(%URI{scheme: scheme, host: host, path: path, port: port}, _url)
       when is_binary(scheme) and is_binary(host) do
    [scheme, "://", host, port_suffix(scheme, port), redact_bot_token_path(path || "")]
  end

  defp sanitized_url_parts(_uri, url) do
    url
    |> String.split(["?", "#"], parts: 2)
    |> List.first()
    |> redact_bot_token_path()
  end

  @spec port_suffix(String.t(), :inet.port_number() | nil) :: String.t()
  defp port_suffix("http", 80), do: ""
  defp port_suffix("https", 443), do: ""
  defp port_suffix(_scheme, nil), do: ""
  defp port_suffix(_scheme, port), do: ":#{port}"

  @spec redact_bot_token_path(String.t()) :: String.t()
  defp redact_bot_token_path(path) do
    Regex.replace(~r{/bot[^/?#]+}, path, "/bot[REDACTED]")
  end

  @spec format_status(Tesla.Env.result()) :: String.t()
  defp format_status({:ok, env}), do: to_string(env.status)
  defp format_status({:error, reason}), do: "error: " <> inspect(reason)
end
