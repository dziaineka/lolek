defmodule Lolek.Url do
  @moduledoc """
  This module is responsible for operations with URLs.
  """

  @threads_hosts ["threads.com", "www.threads.com", "threads.net", "www.threads.net"]
  @url_regex ~r/(:?https|http):\/\/\S+/

  @spec extract_url(String.t()) :: {:ok, String.t()} | {:error, atom()}
  def extract_url(text) do
    case Regex.scan(@url_regex, text) do
      [] ->
        {:error, :no_url}

      urls ->
        url = urls |> List.first() |> List.first()
        normalized_url = normalize_for_allow_list(url)

        allowed_urls_regex = Application.fetch_env!(:lolek, :allowed_urls_regex)

        if Regex.match?(~r/#{allowed_urls_regex}/, normalized_url) do
          {:ok, url}
        else
          {:error, :no_url}
        end
    end
  end

  @spec to_folder_name(String.t()) :: String.t()
  def to_folder_name(url) do
    url
    |> normalize_for_storage()
    |> Base.encode64(padding: false)
  end

  @spec normalize_for_storage(String.t()) :: String.t()
  defp normalize_for_storage(url) do
    case URI.parse(url) do
      %URI{scheme: scheme, host: host, path: path} = uri
      when scheme in ["http", "https"] and host in @threads_hosts and is_binary(path) ->
        normalized_path = String.replace(path, ~r|/media/?$|, "")

        %URI{
          uri
          | scheme: "https",
            host: normalize_threads_host(host),
            path: normalized_path,
            query: nil,
            fragment: nil
        }
        |> URI.to_string()
        |> String.downcase()

      _ ->
        String.downcase(url)
    end
  end

  @spec normalize_for_allow_list(String.t()) :: String.t()
  defp normalize_for_allow_list(url) do
    case normalize_for_storage(url) do
      normalized when is_binary(normalized) -> normalized
      _ -> String.downcase(url)
    end
  end

  @spec normalize_threads_host(String.t()) :: String.t()
  defp normalize_threads_host(host) when host in ["threads.net", "www.threads.net"],
    do: "www.threads.com"

  defp normalize_threads_host(host), do: host
end
