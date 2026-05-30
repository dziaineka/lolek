defmodule Lolek.ThreadsDownloader do
  @moduledoc """
  This module downloads public Threads videos through the web app HTTP endpoints.
  """

  require Logger

  @threads_hosts ["threads.com", "www.threads.com", "threads.net", "www.threads.net"]
  @threads_graphql_url "https://www.threads.com/api/graphql/"
  @threads_ua "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/537.36 " <>
                "(KHTML, like Gecko) Chrome/135.0.0.0 Safari/537.36"

  @shortcode_alphabet "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-_"
  @permalink_query_name "BarcelonaPermalinkMobilePostColumnPageQuery"
  @permalink_query_doc_id "26667056749611275"

  @type token_bundle :: %{
          lsd: String.t(),
          csrf_token: String.t(),
          cookie_csrf_token: String.t() | nil,
          x_bloks_version_id: String.t() | nil,
          provider_variables: %{optional(String.t()) => boolean()}
        }

  @type http_response :: %{body: binary(), headers: [{binary(), binary()}], status: integer()}

  @spec download(String.t(), String.t()) :: {:ok, String.t()} | {:error, String.t()}
  def download(url, output_file_path) do
    with {:ok, normalized_url} <- normalize_url(url),
         media_route_url = media_route_url(normalized_url),
         {:ok, shortcode} <- extract_shortcode(normalized_url),
         {:ok, post_id} <- decode_shortcode(shortcode),
         {:ok, html_response} <- get(normalized_url, html_headers()),
         {:ok, tokens} <- extract_tokens(html_response),
         {:ok, media_url} <-
           fetch_media_url([normalized_url, media_route_url], post_id, tokens) do
      download_media_file(media_url, output_file_path)
    end
  end

  @spec normalize_url(String.t()) :: {:ok, String.t()} | {:error, String.t()}
  def normalize_url(url) do
    case URI.parse(url) do
      %URI{scheme: scheme, host: host, path: path} = uri
      when scheme in ["http", "https"] and host in @threads_hosts and is_binary(path) ->
        normalized_path = String.replace(path, ~r|/media/?$|, "")

        normalized_uri = %URI{
          uri
          | scheme: "https",
            host: normalize_host(host),
            path: normalized_path,
            query: nil,
            fragment: nil
        }

        {:ok, URI.to_string(normalized_uri)}

      _ ->
        {:error, "Unsupported Threads URL"}
    end
  end

  @spec extract_shortcode(String.t()) :: {:ok, String.t()} | {:error, String.t()}
  def extract_shortcode(url) do
    case URI.parse(url) do
      %URI{path: path} when is_binary(path) ->
        case Regex.run(~r|/[^/]+/post/([A-Za-z0-9_-]+)|, path) do
          [_, shortcode] -> {:ok, shortcode}
          _ -> {:error, "Threads post shortcode not found"}
        end

      _ ->
        {:error, "Threads post shortcode not found"}
    end
  end

  @spec decode_shortcode(String.t()) :: {:ok, String.t()} | {:error, String.t()}
  def decode_shortcode(shortcode) when is_binary(shortcode) and shortcode != "" do
    alphabet_index =
      @shortcode_alphabet
      |> String.graphemes()
      |> Enum.with_index()
      |> Map.new()

    shortcode
    |> String.graphemes()
    |> Enum.reduce_while(0, fn character, decoded ->
      case Map.fetch(alphabet_index, character) do
        {:ok, value} -> {:cont, decoded * 64 + value}
        :error -> {:halt, :error}
      end
    end)
    |> case do
      :error -> {:error, "Invalid Threads shortcode"}
      decoded -> {:ok, Integer.to_string(decoded)}
    end
  end

  def decode_shortcode(_shortcode), do: {:error, "Invalid Threads shortcode"}

  @spec extract_tokens(http_response()) :: {:ok, token_bundle()} | {:error, String.t()}
  def extract_tokens(%{body: body, headers: headers}) do
    with {:ok, lsd} <- extract_regex(body, ~r/"LSD",\[\],\{"token":"([^"]+)"/, "LSD token"),
         {:ok, csrf_token} <-
           extract_regex(
             body,
             ~r/InstagramSecurityConfig",\[\],\{"csrf_token":"([^"]+)"/,
             "CSRF token"
           ) do
      {:ok,
       %{
         lsd: lsd,
         csrf_token: csrf_token,
         cookie_csrf_token: extract_header_cookie(headers, "csrftoken"),
         x_bloks_version_id:
           extract_optional_regex(body, ~r/WebBloksVersioningID",\[\],\{"versioningID":"([^"]+)"/),
         provider_variables: extract_provider_variables(body)
       }}
    end
  end

  @spec graphql_requests(String.t(), String.t(), token_bundle()) :: [map()]
  def graphql_requests(url, post_id, tokens) do
    referer = url
    permalink_variables = Map.put(tokens.provider_variables, "postID", post_id)

    [
      %{
        name: @permalink_query_name,
        doc_id: @permalink_query_doc_id,
        endpoint: @threads_graphql_url,
        variables: permalink_variables,
        headers: graphql_headers(tokens, referer, @permalink_query_name)
      },
      %{
        name: @permalink_query_name,
        doc_id: @permalink_query_doc_id,
        endpoint: @threads_graphql_url,
        variables: permalink_variables,
        headers: graphql_headers(tokens, media_route_url(referer), @permalink_query_name)
      }
    ]
  end

  @spec fetch_media_url([String.t()], String.t(), token_bundle()) ::
          {:ok, String.t()} | {:error, String.t()}
  def fetch_media_url(urls, post_id, tokens) do
    urls
    |> Enum.uniq()
    |> Enum.flat_map(&graphql_requests(&1, post_id, tokens))
    |> Enum.reduce_while({:error, "Threads video URL was not found"}, fn request, _acc ->
      handle_graphql_request(request, tokens)
    end)
  end

  @spec handle_graphql_request(map(), token_bundle()) ::
          {:halt, {:ok, String.t()}} | {:cont, {:error, String.t()}}
  defp handle_graphql_request(request, tokens) do
    case execute_graphql_request(request, tokens) do
      {:ok, response} ->
        case extract_media_url(response.body) do
          {:ok, media_url} -> {:halt, {:ok, media_url}}
          {:error, _} -> {:cont, {:error, "Threads video URL was not found"}}
        end

      {:error, reason} ->
        Logger.warning("Threads GraphQL request failed: #{reason}")
        {:cont, {:error, "Threads video URL was not found"}}
    end
  end

  @spec extract_media_url(String.t()) :: {:ok, String.t()} | {:error, String.t()}
  def extract_media_url(body) do
    patterns = [
      ~r/"video_versions"\s*:\s*\[\{[^\]]*?"url"\s*:\s*"([^"]+)"/s,
      ~r/"video_url"\s*:\s*"([^"]+)"/,
      ~r/"dash_manifest"\s*:\s*"([^"]+)"/,
      ~r/"downloadable_uri"\s*:\s*"([^"]+)"/
    ]

    case Enum.find_value(patterns, fn pattern -> extract_optional_regex(body, pattern) end) do
      nil -> {:error, "Threads video URL was not found"}
      encoded_url -> {:ok, decode_json_escaped_url(encoded_url)}
    end
  end

  @spec execute_graphql_request(map(), token_bundle()) ::
          {:ok, http_response()} | {:error, String.t()}
  defp execute_graphql_request(request, tokens) do
    body =
      URI.encode_query(%{
        "fb_api_caller_class" => "RelayModern",
        "fb_api_req_friendly_name" => request.name,
        "server_timestamps" => "true",
        "doc_id" => request.doc_id,
        "variables" => Jason.encode!(request.variables),
        "lsd" => tokens.lsd
      })

    with {:ok, response} <- curl_post(request.endpoint, body, request.headers),
         :ok <- validate_graphql_response(response.body) do
      {:ok, response}
    end
  end

  @spec curl_post(String.t(), String.t(), [{String.t(), String.t()}]) ::
          {:ok, http_response()} | {:error, String.t()}
  defp curl_post(url, body, headers) do
    case System.find_executable("curl") do
      nil ->
        {:error, "curl executable was not found"}

      curl_path ->
        args =
          [
            "-sS",
            "--http1.1",
            "-X",
            "POST",
            url,
            "--data-binary",
            body,
            "-w",
            "\n__CURL_STATUS__:%{http_code}"
          ] ++
            Enum.flat_map(headers, fn {name, value} -> ["-H", "#{name}: #{value}"] end)

        case System.cmd(curl_path, args, stderr_to_stdout: true) do
          {response, 0} ->
            parse_curl_response(response)

          {response, exit_code} ->
            {:error, "curl POST failed with exit code #{exit_code}: #{String.trim(response)}"}
        end
    end
  end

  @spec parse_curl_response(String.t()) :: {:ok, http_response()} | {:error, String.t()}
  defp parse_curl_response(response) do
    marker = "\n__CURL_STATUS__:"

    case String.split(response, marker, parts: 2) do
      [body, status] ->
        case Integer.parse(String.trim(status)) do
          {http_status, ""} when http_status in 200..299 ->
            {:ok, %{status: http_status, body: body, headers: []}}

          {http_status, ""} ->
            {:error, "HTTP POST failed with status #{http_status}"}

          _ ->
            {:error, "curl response status could not be parsed"}
        end

      _ ->
        {:error, "curl response status marker was not found"}
    end
  end

  @spec download_media_file(String.t(), String.t()) :: {:ok, String.t()} | {:error, String.t()}
  defp download_media_file(media_url, output_file_path) do
    Lolek.StreamDownload.download(media_url, output_file_path, download_headers())
  end

  @spec get(String.t(), [{String.t(), String.t()}]) ::
          {:ok, http_response()} | {:error, String.t()}
  defp get(url, headers) do
    case Tesla.get(client(), url, headers: headers) do
      {:ok, %Tesla.Env{status: status, body: body, headers: response_headers}}
      when status in 200..299 ->
        {:ok, %{status: status, body: to_string(body), headers: response_headers}}

      {:ok, %Tesla.Env{status: status}} ->
        {:error, "HTTP GET failed with status #{status}"}

      {:error, reason} ->
        {:error, format_error(reason)}
    end
  end

  @spec client() :: Tesla.Client.t()
  defp client do
    Tesla.client(
      [
        {Tesla.Middleware.FollowRedirects, max_redirects: 5},
        {Tesla.Middleware.Headers, [{"user-agent", @threads_ua}]}
      ],
      Tesla.Adapter.Hackney
    )
  end

  @spec normalize_host(String.t()) :: String.t()
  defp normalize_host(host) when host in ["threads.net", "www.threads.net"], do: "www.threads.com"
  defp normalize_host(host), do: host

  @spec html_headers() :: [{String.t(), String.t()}]
  defp html_headers do
    [
      {"accept", "text/html,application/xhtml+xml"},
      {"accept-language", "en-US,en;q=0.9"}
    ]
  end

  @spec download_headers() :: [{String.t(), String.t()}]
  defp download_headers do
    [
      {"user-agent", @threads_ua},
      {"accept", "*/*"},
      {"accept-language", "en-US,en;q=0.9"}
    ]
  end

  @spec graphql_headers(token_bundle(), String.t(), String.t()) ::
          [{String.t(), String.t()}]
  defp graphql_headers(tokens, referer, query_name) do
    headers = [
      {"accept", "*/*"},
      {"content-type", "application/x-www-form-urlencoded"},
      {"origin", "https://www.threads.com"},
      {"referer", referer},
      {"accept-language", "en-US,en;q=0.9"},
      {"x-csrftoken", tokens.csrf_token},
      {"x-fb-friendly-name", query_name},
      {"x-ig-app-id", "238260118697367"}
    ]

    headers =
      case tokens.cookie_csrf_token do
        nil -> headers
        cookie_csrf_token -> [{"cookie", "csrftoken=#{cookie_csrf_token}"} | headers]
      end

    case tokens.x_bloks_version_id do
      nil -> headers
      version_id -> [{"x-bloks-version-id", version_id} | headers]
    end
  end

  @spec extract_provider_variables(String.t()) :: %{optional(String.t()) => boolean()}
  defp extract_provider_variables(body) do
    %{
      "__relay_internal__pv__BarcelonaCanSeeSponsoredContentrelayprovider" => false,
      "__relay_internal__pv__BarcelonaHasCommunitiesrelayprovider" => extract_gkx(body, "6542"),
      "__relay_internal__pv__BarcelonaHasCommunityEntityCardrelayprovider" =>
        extract_gkx(body, "23446"),
      "__relay_internal__pv__BarcelonaHasCommunityTopContributorsrelayprovider" =>
        extract_gkx(body, "17942"),
      "__relay_internal__pv__BarcelonaHasDearAlgoConsumptionrelayprovider" =>
        extract_gkx(body, "4511"),
      "__relay_internal__pv__BarcelonaHasDearAlgoWebProductionrelayprovider" =>
        extract_gkx(body, "14866"),
      "__relay_internal__pv__BarcelonaHasEventBadgerelayprovider" => extract_gkx(body, "3960"),
      "__relay_internal__pv__BarcelonaHasGameScoreSharerelayprovider" =>
        extract_gkx(body, "18268"),
      "__relay_internal__pv__BarcelonaHasGhostPostEmojiActivationrelayprovider" =>
        extract_gkx(body, "1636"),
      "__relay_internal__pv__BarcelonaHasInlineReplyComposerrelayprovider" =>
        extract_qex(body, "1013"),
      "__relay_internal__pv__BarcelonaHasMessagingrelayprovider" => extract_qex(body, "552"),
      "__relay_internal__pv__BarcelonaHasMusicrelayprovider" => extract_gkx(body, "10317"),
      "__relay_internal__pv__BarcelonaHasNewspaperLinkStylerelayprovider" =>
        extract_gkx(body, "15632"),
      "__relay_internal__pv__BarcelonaHasPublicViewCountCardrelayprovider" =>
        extract_gkx(body, "21940"),
      "__relay_internal__pv__BarcelonaHasScorecardCommunityrelayprovider" =>
        extract_gkx(body, "22721"),
      "__relay_internal__pv__BarcelonaIsCrawlerrelayprovider" => extract_gkx(body, "22947"),
      "__relay_internal__pv__BarcelonaIsInternalUserrelayprovider" => extract_gkx(body, "8271"),
      "__relay_internal__pv__BarcelonaIsLoggedInrelayprovider" => extract_gkx(body, "7479"),
      "__relay_internal__pv__BarcelonaIsSearchDiscoveryEnabledrelayprovider" =>
        extract_gkx(body, "10813"),
      "__relay_internal__pv__BarcelonaOptionalCookiesEnabledrelayprovider" =>
        extract_gkx(body, "8583"),
      "__relay_internal__pv__BarcelonaShouldShowFediverseM075Featuresrelayprovider" =>
        extract_meta_config(body, "92")
    }
  end

  @spec extract_gkx(String.t(), String.t()) :: boolean()
  defp extract_gkx(body, id) do
    String.contains?(body, ~s("#{id}":{"result":true))
  end

  @spec extract_qex(String.t(), String.t()) :: boolean()
  defp extract_qex(body, id) do
    String.contains?(body, ~s("#{id}":{"r":true))
  end

  @spec extract_meta_config(String.t(), String.t()) :: boolean()
  defp extract_meta_config(body, id) do
    String.contains?(body, ~s("#{id}":{"value":true))
  end

  @spec extract_regex(String.t(), Regex.t(), String.t()) ::
          {:ok, String.t()} | {:error, String.t()}
  defp extract_regex(body, regex, label) do
    case Regex.run(regex, body) do
      [_, value] -> {:ok, value}
      _ -> {:error, "Threads #{label} was not found"}
    end
  end

  @spec extract_optional_regex(String.t(), Regex.t()) :: String.t() | nil
  defp extract_optional_regex(body, regex) do
    case Regex.run(regex, body) do
      [_, value] -> value
      _ -> nil
    end
  end

  @spec extract_header_cookie([{binary(), binary()}], String.t()) :: String.t() | nil
  defp extract_header_cookie(headers, cookie_name) do
    Enum.find_value(headers, &header_cookie_value(&1, cookie_name))
  end

  @spec header_cookie_value({binary(), binary()}, String.t()) :: String.t() | nil
  defp header_cookie_value({header_name, value}, cookie_name) do
    if String.downcase(header_name) == "set-cookie" do
      case Regex.run(~r/#{cookie_name}=([^;]+)/, value) do
        [_, cookie_value] -> cookie_value
        _ -> nil
      end
    end
  end

  @spec decode_json_escaped_url(String.t()) :: String.t()
  defp decode_json_escaped_url(encoded_url) do
    encoded_url
    |> String.replace("\\/", "/")
    |> String.replace("&amp;", "&")
    |> URI.decode()
  end

  @spec media_route_url(String.t()) :: String.t()
  defp media_route_url(url) do
    uri = URI.parse(url)
    path = uri.path |> String.trim_trailing("/") |> Kernel.<>("/media")
    URI.to_string(%URI{uri | path: path})
  end

  @spec format_error(term()) :: String.t()
  defp format_error(reason) when is_binary(reason), do: reason
  defp format_error(reason), do: inspect(reason)

  @spec validate_graphql_response(String.t()) :: :ok | {:error, String.t()}
  defp validate_graphql_response(body) do
    cond do
      String.starts_with?(body, "<!DOCTYPE html>") ->
        {:error, "Threads returned HTML instead of GraphQL JSON"}

      String.contains?(body, "missing_required_variable_value") ->
        {:error, "Threads GraphQL request is missing required variables"}

      String.contains?(body, "\"errors\"") and not String.contains?(body, "\"video_versions\"") ->
        {:error, "Threads GraphQL returned errors"}

      true ->
        :ok
    end
  end
end
