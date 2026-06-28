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
    case File.mkdir_p(Path.dirname(output_file_path)) do
      :ok -> stream_to_file(url, output_file_path, headers, max_bytes)
      {:error, reason} -> {:error, format_error(reason)}
    end
  end

  @spec stream_to_file(String.t(), String.t(), [header()], non_neg_integer()) ::
          {:ok, String.t()} | {:error, String.t()}
  defp stream_to_file(url, output_file_path, headers, max_bytes) do
    temp_path = output_file_path <> ".part"
    _ = File.rm(temp_path)

    case File.open(temp_path, [:write, :binary]) do
      {:ok, file} ->
        result =
          Req.get(url,
            headers: headers,
            max_redirects: 5,
            into: &stream_chunk(&1, &2, file, max_bytes)
          )

        _ = File.close(file)
        handle_result(result, url, temp_path, output_file_path)

      {:error, reason} ->
        {:error, format_error(reason)}
    end
  end

  @spec handle_result(
          {:ok, Req.Response.t()} | {:error, term()},
          String.t(),
          String.t(),
          String.t()
        ) :: {:ok, String.t()} | {:error, String.t()}
  defp handle_result({:ok, %Req.Response{status: status}}, _url, temp_path, _out)
       when status not in 200..299 do
    _ = File.rm(temp_path)
    {:error, "HTTP GET failed with status #{status}"}
  end

  defp handle_result({:ok, resp}, url, temp_path, output_file_path) do
    case Map.get(resp.private, :stream_error) do
      nil ->
        extension = file_extension(url, resp)
        file_path = output_file_path <> extension

        case File.rename(temp_path, file_path) do
          :ok ->
            {:ok, file_path}

          {:error, reason} ->
            _ = File.rm(temp_path)
            {:error, format_error(reason)}
        end

      error_msg ->
        _ = File.rm(temp_path)
        {:error, error_msg}
    end
  end

  defp handle_result({:error, reason}, _url, temp_path, _out) do
    _ = File.rm(temp_path)
    {:error, format_error(reason)}
  end

  @spec stream_chunk(
          {:data, binary()},
          {Req.Request.t(), Req.Response.t()},
          File.io_device(),
          non_neg_integer()
        ) :: {:cont | :halt, {Req.Request.t(), Req.Response.t()}}
  defp stream_chunk({:data, chunk}, {req, resp}, file, max_bytes) do
    private = initial_checks(resp.private, resp, max_bytes)

    case Map.get(private, :stream_error) do
      nil -> write_chunk(chunk, req, resp, private, file, max_bytes)
      _error -> {:halt, {req, %{resp | private: private}}}
    end
  end

  @spec initial_checks(map(), Req.Response.t(), non_neg_integer()) :: map()
  defp initial_checks(%{initial_checked: true} = private, _resp, _max_bytes), do: private

  defp initial_checks(private, resp, max_bytes) do
    private = Map.put(private, :initial_checked, true)

    cond do
      resp.status not in 200..299 ->
        Map.put(private, :stream_error, "HTTP GET failed with status #{resp.status}")

      content_length_exceeds?(resp, max_bytes) ->
        Map.put(private, :stream_error, oversized_error(max_bytes))

      true ->
        private
    end
  end

  @spec write_chunk(
          binary(),
          Req.Request.t(),
          Req.Response.t(),
          map(),
          File.io_device(),
          non_neg_integer()
        ) :: {:cont | :halt, {Req.Request.t(), Req.Response.t()}}
  defp write_chunk(chunk, req, resp, private, file, max_bytes) do
    new_bytes = Map.get(private, :bytes_written, 0) + byte_size(chunk)

    if new_bytes > max_bytes do
      private = Map.put(private, :stream_error, oversized_error(max_bytes))
      {:halt, {req, %{resp | private: private}}}
    else
      _ = IO.binwrite(file, chunk)
      {:cont, {req, %{resp | private: Map.put(private, :bytes_written, new_bytes)}}}
    end
  end

  @spec file_extension(String.t(), Req.Response.t()) :: String.t()
  defp file_extension(url, resp) do
    case Path.extname(URI.parse(url).path || "") do
      "" -> extension_from_content_type(resp)
      extension -> extension
    end
  end

  @spec extension_from_content_type(Req.Response.t()) :: String.t()
  defp extension_from_content_type(resp) do
    case Req.Response.get_header(resp, "content-type") do
      ["video/mp4" <> _ | _] -> ".mp4"
      ["application/dash+xml" <> _ | _] -> ".mpd"
      _ -> ".mp4"
    end
  end

  @spec content_length_exceeds?(Req.Response.t(), non_neg_integer()) :: boolean()
  defp content_length_exceeds?(resp, max_bytes) do
    case Req.Response.get_header(resp, "content-length") do
      [value | _] ->
        case Integer.parse(String.trim(value)) do
          {length, ""} -> length > max_bytes
          _ -> false
        end

      _ ->
        false
    end
  end

  @spec oversized_error(non_neg_integer()) :: String.t()
  defp oversized_error(max_bytes) do
    "Downloaded file exceeded maximum size of #{max_bytes} bytes"
  end

  @spec format_error(term()) :: String.t()
  defp format_error(reason) when is_exception(reason), do: Exception.message(reason)
  defp format_error(reason), do: inspect(reason)
end
