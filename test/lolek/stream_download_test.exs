defmodule Lolek.StreamDownloadTest do
  use ExUnit.Case, async: true

  setup_all do
    {:ok, _apps} = Application.ensure_all_started(:hackney)
    :ok
  end

  @tag :tmp_dir
  test "streams response body to disk using content type extension", %{tmp_dir: tmp_dir} do
    url =
      serve_response(
        "/media",
        ["one", "two", "three"],
        [{"content-type", "video/mp4"}]
      )

    output_file_path = Path.join(tmp_dir, "downloaded")

    assert {:ok, file_path} =
             Lolek.StreamDownload.download(url, output_file_path, [], 100)

    assert file_path == output_file_path <> ".mp4"
    assert File.read!(file_path) == "onetwothree"
  end

  @tag :tmp_dir
  test "uses extension from url before content type", %{tmp_dir: tmp_dir} do
    url =
      serve_response(
        "/media.mpd",
        ["manifest"],
        [{"content-type", "video/mp4"}]
      )

    output_file_path = Path.join(tmp_dir, "downloaded")

    assert {:ok, file_path} =
             Lolek.StreamDownload.download(url, output_file_path, [], 100)

    assert file_path == output_file_path <> ".mpd"
    assert File.read!(file_path) == "manifest"
  end

  @tag :tmp_dir
  test "rejects oversized responses before reading known content length", %{tmp_dir: tmp_dir} do
    url =
      serve_response(
        "/media.mp4",
        ["too large"],
        [{"content-length", "100"}, {"content-type", "video/mp4"}]
      )

    output_file_path = Path.join(tmp_dir, "downloaded")

    assert {:error, reason} =
             Lolek.StreamDownload.download(url, output_file_path, [], 10)

    assert reason =~ "exceeded maximum size"
    refute File.exists?(output_file_path <> ".mp4")
    refute File.exists?(output_file_path <> ".mp4.part")
  end

  @tag :tmp_dir
  test "removes partial file when streamed response exceeds limit", %{tmp_dir: tmp_dir} do
    url =
      serve_response(
        "/media.mp4",
        ["1234", "5678"],
        [{"content-type", "video/mp4"}],
        include_content_length: false
      )

    output_file_path = Path.join(tmp_dir, "downloaded")

    assert {:error, reason} =
             Lolek.StreamDownload.download(url, output_file_path, [], 5)

    assert reason =~ "exceeded maximum size"
    refute File.exists?(output_file_path <> ".mp4")
    refute File.exists?(output_file_path <> ".mp4.part")
  end

  defp serve_response(path, chunks, headers, opts \\ []) do
    {:ok, listen_socket} =
      :gen_tcp.listen(0, [
        :binary,
        packet: :raw,
        active: false,
        reuseaddr: true,
        ip: {127, 0, 0, 1}
      ])

    {:ok, port} = :inet.port(listen_socket)
    parent = self()

    server_pid =
      spawn_link(fn ->
        {:ok, socket} = :gen_tcp.accept(listen_socket)
        read_request(socket)
        send_response(socket, chunks, headers, opts)
        :gen_tcp.close(socket)
        :gen_tcp.close(listen_socket)
        send(parent, {:served, self()})
      end)

    on_exit(fn ->
      if Process.alive?(server_pid), do: Process.exit(server_pid, :kill)
      :gen_tcp.close(listen_socket)
    end)

    "http://127.0.0.1:#{port}#{path}"
  end

  defp read_request(socket, acc \\ "") do
    case :gen_tcp.recv(socket, 0, 1_000) do
      {:ok, data} ->
        acc = acc <> data

        if String.contains?(acc, "\r\n\r\n") do
          acc
        else
          read_request(socket, acc)
        end

      {:error, _reason} ->
        acc
    end
  end

  defp send_response(socket, chunks, headers, opts) do
    headers =
      if Keyword.get(opts, :include_content_length, true) and
           not header_present?(headers, "content-length") do
        [{"content-length", chunks_size(chunks)} | headers]
      else
        headers
      end

    response_headers =
      headers
      |> Enum.map_join(fn {name, value} -> "#{name}: #{value}\r\n" end)

    :ok = :gen_tcp.send(socket, "HTTP/1.1 200 OK\r\n" <> response_headers <> "\r\n")
    Enum.each(chunks, &:gen_tcp.send(socket, &1))
  end

  defp header_present?(headers, header_name) do
    Enum.any?(headers, fn {name, _value} -> String.downcase(name) == header_name end)
  end

  defp chunks_size(chunks) do
    chunks
    |> Enum.map(&byte_size/1)
    |> Enum.sum()
    |> Integer.to_string()
  end
end
