defmodule AriadnaMCP.ClosingAdapter do
  @moduledoc false
  # A Plug test adapter whose client goes away after the first chunk, to prove
  # that closing an SSE stream cancels the tool call.
  @behaviour Plug.Conn.Adapter

  alias Plug.Adapters.Test.Conn, as: TestConn

  def wrap(%Plug.Conn{adapter: {TestConn, state}} = conn),
    do: %{conn | adapter: {__MODULE__, {state, 0}}}

  @impl true
  def chunk({state, 0}, data) do
    {:ok, body, state} = TestConn.chunk(state, data)
    {:ok, body, {state, 1}}
  end

  def chunk({_state, _sent}, _data), do: {:error, :closed}

  @impl true
  def send_chunked({state, sent}, status, headers) do
    {:ok, body, state} = TestConn.send_chunked(state, status, headers)
    {:ok, body, {state, sent}}
  end

  @impl true
  def send_resp({state, sent}, status, headers, body) do
    {:ok, body, state} = TestConn.send_resp(state, status, headers, body)
    {:ok, body, {state, sent}}
  end

  @impl true
  def read_req_body({state, sent}, opts) do
    case TestConn.read_req_body(state, opts) do
      {status, body, state} -> {status, body, {state, sent}}
    end
  end

  @impl true
  def get_peer_data({state, _sent}), do: TestConn.get_peer_data(state)
  @impl true
  def get_http_protocol({state, _sent}), do: TestConn.get_http_protocol(state)
  @impl true
  def get_sock_data({state, _sent}), do: TestConn.get_sock_data(state)
  @impl true
  def get_ssl_data({state, _sent}), do: TestConn.get_ssl_data(state)
  @impl true
  def send_file(_payload, _status, _headers, _path, _offset, _length), do: raise("not used")
  @impl true
  def inform(_payload, _status, _headers), do: {:error, :not_supported}
  @impl true
  def upgrade(_payload, _protocol, _opts), do: {:error, :not_supported}
  @impl true
  def push(_payload, _path, _headers), do: {:error, :not_supported}
end
