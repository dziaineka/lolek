defmodule Lolek.MetricsEndpoint do
  @moduledoc """
  Serves collected metrics through a small local HTTP endpoint.
  """

  use GenServer

  @request_timeout_ms 5_000

  @type state :: %{
          socket: :gen_tcp.socket(),
          acceptor: pid()
        }

  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(opts \\ []) do
    name = Keyword.get(opts, :name, __MODULE__)
    GenServer.start_link(__MODULE__, opts, name: name)
  end

  @impl true
  @spec init(keyword()) :: {:ok, state()} | {:stop, term()}
  def init(opts) do
    Process.flag(:trap_exit, true)

    listen_address =
      Keyword.get_lazy(opts, :listen_address, fn ->
        Application.fetch_env!(:lolek, :metrics_listen_address)
      end)

    port =
      Keyword.get_lazy(opts, :port, fn ->
        Application.fetch_env!(:lolek, :metrics_port)
      end)

    with {:ok, ip_address} <- parse_ip_address(listen_address),
         :ok <- validate_port(port),
         {:ok, socket} <- listen(ip_address, port) do
      acceptor = spawn_link(fn -> accept_loop(socket) end)
      {:ok, %{socket: socket, acceptor: acceptor}}
    else
      {:error, reason} -> {:stop, reason}
    end
  end

  @impl true
  def handle_info({:EXIT, acceptor, :normal}, %{acceptor: acceptor} = state),
    do: {:noreply, state}

  def handle_info({:EXIT, acceptor, :closed}, %{acceptor: acceptor} = state),
    do: {:noreply, state}

  def handle_info({:EXIT, acceptor, reason}, %{acceptor: acceptor} = state) do
    {:stop, {:acceptor_exited, reason}, state}
  end

  @impl true
  def terminate(_reason, state) do
    :gen_tcp.close(state.socket)
    :ok
  end

  @spec listen(:inet.ip_address(), :inet.port_number()) ::
          {:ok, :gen_tcp.socket()} | {:error, term()}
  defp listen(ip_address, port) do
    :gen_tcp.listen(port, [
      :binary,
      active: false,
      packet: :raw,
      reuseaddr: true,
      ip: ip_address
    ])
  end

  @spec accept_loop(:gen_tcp.socket()) :: :ok
  defp accept_loop(socket) do
    case :gen_tcp.accept(socket) do
      {:ok, client} ->
        spawn(fn -> serve_client(client) end)
        accept_loop(socket)

      {:error, :closed} ->
        exit(:closed)

      {:error, _reason} ->
        accept_loop(socket)
    end
  end

  @spec serve_client(:gen_tcp.socket()) :: :ok
  defp serve_client(client) do
    case read_request(client, "") do
      {:ok, request} ->
        {status, body, content_type} = response(request)
        send_response(client, status, body, content_type)

      {:error, _reason} ->
        send_response(client, 400, "bad request\n", "text/plain; charset=utf-8")
    end

    :gen_tcp.close(client)
    :ok
  end

  @spec read_request(:gen_tcp.socket(), String.t()) :: {:ok, String.t()} | {:error, term()}
  defp read_request(client, acc) do
    if String.contains?(acc, "\r\n\r\n") do
      {:ok, acc}
    else
      case :gen_tcp.recv(client, 0, @request_timeout_ms) do
        {:ok, data} -> read_request(client, acc <> data)
        {:error, reason} -> {:error, reason}
      end
    end
  end

  @spec response(String.t()) :: {non_neg_integer(), String.t(), String.t()}
  defp response(request) do
    case request_line(request) do
      ["GET", "/metrics", _version] ->
        {200, Lolek.Metrics.prometheus_text(), "text/plain; version=0.0.4; charset=utf-8"}

      ["GET", _path, _version] ->
        {404, "not found\n", "text/plain; charset=utf-8"}

      [_method, _path, _version] ->
        {405, "method not allowed\n", "text/plain; charset=utf-8"}

      _ ->
        {400, "bad request\n", "text/plain; charset=utf-8"}
    end
  end

  @spec request_line(String.t()) :: [String.t()]
  defp request_line(request) do
    request
    |> String.split("\r\n", parts: 2)
    |> List.first()
    |> String.split(" ", parts: 3)
  end

  @spec send_response(:gen_tcp.socket(), non_neg_integer(), String.t(), String.t()) :: :ok
  defp send_response(client, status, body, content_type) do
    status_line = status_line(status)

    response = [
      "HTTP/1.1 #{status} #{status_line}\r\n",
      "content-type: #{content_type}\r\n",
      "content-length: #{byte_size(body)}\r\n",
      "connection: close\r\n",
      "\r\n",
      body
    ]

    :gen_tcp.send(client, response)
    :ok
  end

  @spec status_line(non_neg_integer()) :: String.t()
  defp status_line(200), do: "OK"
  defp status_line(400), do: "Bad Request"
  defp status_line(404), do: "Not Found"
  defp status_line(405), do: "Method Not Allowed"
  defp status_line(_status), do: "Error"

  @spec parse_ip_address(String.t()) :: {:ok, :inet.ip_address()} | {:error, term()}
  defp parse_ip_address(listen_address) do
    listen_address
    |> to_charlist()
    |> :inet.parse_address()
    |> case do
      {:ok, ip_address} -> {:ok, ip_address}
      {:error, reason} -> {:error, {:invalid_metrics_listen_address, listen_address, reason}}
    end
  end

  @spec validate_port(term()) :: :ok | {:error, term()}
  defp validate_port(port) when is_integer(port) and port > 0 and port <= 65_535, do: :ok
  defp validate_port(port), do: {:error, {:invalid_metrics_port, port}}
end
