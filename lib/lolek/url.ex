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

        if allowed_url?(url) do
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

  @spec allowed_url?(String.t()) :: boolean()
  defp allowed_url?(url) do
    allowed_urls_regex = Application.fetch_env!(:lolek, :allowed_urls_regex)

    case URI.parse(url) do
      %URI{scheme: scheme, host: host} = uri
      when scheme in ["http", "https"] and is_binary(host) ->
        allowed_url_regex = ~r{^(?:#{allowed_urls_regex})(?:$|/)}
        uri |> normalize_for_allow_list() |> Enum.any?(&Regex.match?(allowed_url_regex, &1))

      _ ->
        false
    end
  end

  @spec normalize_for_allow_list(URI.t()) :: [String.t()]
  defp normalize_for_allow_list(%URI{host: host, path: path}) do
    path = String.downcase(path || "/")

    host
    |> String.downcase()
    |> String.split(".")
    |> host_suffixes()
    |> Enum.map(&(&1 <> path))
  end

  @spec host_suffixes([String.t()]) :: [String.t()]
  defp host_suffixes([]), do: []

  defp host_suffixes([_last_label] = labels), do: [Enum.join(labels, ".")]

  defp host_suffixes(labels) do
    [Enum.join(labels, ".") | host_suffixes(tl(labels))]
  end

  @spec normalize_threads_host(String.t()) :: String.t()
  defp normalize_threads_host(host) when host in ["threads.net", "www.threads.net"],
    do: "www.threads.com"

  defp normalize_threads_host(host), do: host
end
