defmodule Lolek.StreamDownload do
  @moduledoc """
  Downloads HTTP response bodies directly to disk without buffering them in memory.
  """

  @type header :: {String.t(), String.t()}

  @spec download(String.t(), String.t(), [header()]) :: {:ok, String.t()} | {:error, String.t()}
  def download(url, output_file_path, headers) do
    max_bytes = Application.fetch_env!(:lolek, :max_file_size_to_compress)
    download(url, output_file_path, headers, max_bytes)
  end

  @spec download(String.t(), String.t(), [header()], non_neg_integer()) ::
          {:ok, String.t()} | {:error, String.t()}
  def download(url, output_file_path, headers, max_bytes) do
    with :ok <- File.mkdir_p(Path.dirname(output_file_path)),
         {:ok, status, response_headers, client_ref} <- request(url, headers),
         :ok <- validate_status(status, client_ref),
         :ok <- validate_content_length(response_headers, max_bytes, client_ref),
         extension <- file_extension(url, response_headers),
         file_path <- output_file_path <> extension,
         :ok <- stream_to_file(client_ref, file_path, max_bytes) do
      {:ok, file_path}
    else
      {:error, reason} -> {:error, format_error(reason)}
    end
  end

  @spec request(String.t(), [header()]) ::
          {:ok, integer(), [header()], reference()} | {:error, term()}
  defp request(url, headers) do
    :hackney.request(:get, url, headers, "", follow_redirect: true, max_redirect: 5)
  end

  @spec validate_status(integer(), reference()) :: :ok | {:error, String.t()}
  defp validate_status(status, _client_ref) when status in 200..299 do
    :ok
  end

  defp validate_status(status, client_ref) do
    _ = :hackney.close(client_ref)
    {:error, "HTTP GET failed with status #{status}"}
  end

  @spec validate_content_length([header()], non_neg_integer(), reference()) ::
          :ok | {:error, String.t()}
  defp validate_content_length(headers, max_bytes, client_ref) do
    case content_length(headers) do
      length when is_integer(length) and length > max_bytes ->
        _ = :hackney.close(client_ref)
        {:error, oversized_error(max_bytes)}

      _ ->
        :ok
    end
  end

  @spec stream_to_file(reference(), String.t(), non_neg_integer()) ::
          :ok | {:error, String.t()}
  defp stream_to_file(client_ref, file_path, max_bytes) do
    temp_file_path = file_path <> ".part"
    _ = File.rm(temp_file_path)

    case File.open(temp_file_path, [:write, :binary], fn file ->
           stream_chunks(client_ref, file, 0, max_bytes)
         end) do
      {:ok, :ok} ->
        _ = :hackney.close(client_ref)

        case File.rename(temp_file_path, file_path) do
          :ok ->
            :ok

          {:error, reason} ->
            _ = File.rm(temp_file_path)
            {:error, reason}
        end

      {:ok, {:error, reason}} ->
        _ = :hackney.close(client_ref)
        _ = File.rm(temp_file_path)
        {:error, reason}

      {:error, reason} ->
        _ = :hackney.close(client_ref)
        _ = File.rm(temp_file_path)
        {:error, reason}
    end
  end

  @spec stream_chunks(reference(), File.io_device(), non_neg_integer(), non_neg_integer()) ::
          :ok | {:error, String.t()}
  defp stream_chunks(client_ref, file, bytes_downloaded, max_bytes) do
    case :hackney.stream_body(client_ref) do
      {:ok, chunk} ->
        new_bytes_downloaded = bytes_downloaded + byte_size(chunk)

        if new_bytes_downloaded > max_bytes do
          {:error, oversized_error(max_bytes)}
        else
          :ok = IO.binwrite(file, chunk)
          stream_chunks(client_ref, file, new_bytes_downloaded, max_bytes)
        end

      :done ->
        :ok

      {:error, reason} ->
        {:error, "HTTP response stream failed: #{format_error(reason)}"}
    end
  end

  @spec file_extension(String.t(), [header()]) :: String.t()
  defp file_extension(media_url, headers) do
    case Path.extname(URI.parse(media_url).path || "") do
      "" -> extension_from_content_type(headers)
      extension -> extension
    end
  end

  @spec extension_from_content_type([header()]) :: String.t()
  defp extension_from_content_type(headers) do
    case content_type_header(headers) do
      "video/mp4" <> _ -> ".mp4"
      "application/dash+xml" <> _ -> ".mpd"
      _ -> ".mp4"
    end
  end

  @spec content_type_header([header()]) :: String.t() | nil
  defp content_type_header(headers) do
    header_value(headers, "content-type")
  end

  @spec content_length([header()]) :: non_neg_integer() | nil
  defp content_length(headers) do
    with value when is_binary(value) <- header_value(headers, "content-length"),
         {length, ""} <- Integer.parse(String.trim(value)) do
      length
    else
      _ -> nil
    end
  end

  @spec header_value([header()], String.t()) :: String.t() | nil
  defp header_value(headers, header_name) do
    Enum.find_value(headers, fn
      {name, value} ->
        if String.downcase(to_string(name)) == header_name do
          String.downcase(to_string(value))
        end

      _ ->
        nil
    end)
  end

  @spec oversized_error(non_neg_integer()) :: String.t()
  defp oversized_error(max_bytes) do
    "Downloaded file exceeded maximum size of #{max_bytes} bytes"
  end

  @spec format_error(term()) :: String.t()
  defp format_error(reason) when is_binary(reason), do: reason
  defp format_error(reason), do: inspect(reason)
end
