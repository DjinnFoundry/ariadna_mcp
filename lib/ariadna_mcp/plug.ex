defmodule AriadnaMCP.Plug do
  @moduledoc """
  Streamable HTTP transport, without sessions.

      # Phoenix router, after the pipeline that authenticates the client
      scope "/api" do
        pipe_through :mcp
        forward "/mcp", AriadnaMCP.Plug, server: MyApp.MCP, client_name: &MyApp.MCP.client_name/1
      end

  Each POST carries one JSON-RPC message and gets one answer: JSON, or an SSE
  stream when a `tools/call` asks for progress (a `progressToken` in `_meta`)
  and accepts `text/event-stream`. Closing that stream cancels the call. GET
  and DELETE answer 405: there is no server stream and no session.

  Options:

    * `:server` (required) - the `AriadnaMCP.Server` module.
    * `:client` - a function `conn -> client`; defaults to `conn.assigns.current_client`.
    * `:client_name` - a function `client -> name` for telemetry and audit;
      defaults to the client's `:name`.
    * `:assigns` - a function `conn -> map` copied into the context.

  Pass functions as remote captures (`&MyApp.MCP.client_name/1`): Phoenix runs
  `init/1` at compile time and cannot embed anonymous functions.
    * `:allowed_origins` - DNS rebinding protection for requests that carry an
      `Origin` header: `:same_origin` (default) accepts an origin whose host is
      the request's own `Host`; a list accepts those origins as well; `:any`
      accepts all. Anything else gets 403. Requests without `Origin` pass.
    * `:keepalive` - milliseconds between SSE keep-alive comments (15 000).
  """

  @behaviour Plug

  import Plug.Conn

  alias AriadnaMCP.{Context, Protocol}

  @keepalive 15_000

  @impl Plug
  def init(opts) do
    %{
      server: Keyword.fetch!(opts, :server),
      client: Keyword.get(opts, :client, &__MODULE__.current_client/1),
      client_name: Keyword.get(opts, :client_name, &__MODULE__.client_name/1),
      assigns: Keyword.get(opts, :assigns, &__MODULE__.no_assigns/1),
      allowed_origins: Keyword.get(opts, :allowed_origins, :same_origin),
      keepalive: Keyword.get(opts, :keepalive, @keepalive)
    }
  end

  @impl Plug
  def call(%Plug.Conn{method: "POST"} = conn, opts) do
    with :ok <- check_origin(conn, opts),
         {:ok, message, conn} <- read_message(conn) do
      serve(conn, message, opts)
    else
      {:reply, status, body, conn} -> send_json(conn, status, body)
    end
  end

  def call(conn, _opts) do
    conn
    |> put_resp_header("allow", "POST")
    |> send_resp(405, "")
    |> halt()
  end

  defp serve(conn, message, opts) do
    client = opts.client.(conn)

    context = %Context{
      client: client,
      client_name: client && opts.client_name.(client),
      assigns: opts.assigns.(conn)
    }

    case Protocol.negotiate(message, context, headers(conn)) do
      {:reply, status, body} ->
        send_json(conn, status, body)

      {:ok, context} ->
        if stream?(conn, message, context) do
          stream(conn, message, context, opts)
        else
          {status, body} = Protocol.dispatch(opts.server, message, context)
          send_json(conn, status, body)
        end
    end
  end

  defp stream?(conn, message, context) do
    message["method"] == "tools/call" and Map.has_key?(message, "id") and
      not is_nil(context.progress_token || get_in(message, ["params", "_meta", "progressToken"])) and
      conn |> get_req_header("accept") |> Enum.any?(&String.contains?(&1, "text/event-stream"))
  end

  defp stream(conn, message, context, opts) do
    parent = self()
    tag = make_ref()
    token = context.progress_token || get_in(message, ["params", "_meta", "progressToken"])

    context = %{
      context
      | progress_token: token,
        progress_fun: fn params ->
          send(parent, {tag, :progress, params})
          :ok
        end
    }

    task = Task.async(fn -> Protocol.dispatch(opts.server, message, context) end)

    conn =
      conn
      |> put_resp_content_type("text/event-stream")
      |> put_resp_header("cache-control", "no-cache")
      |> put_resp_header("x-accel-buffering", "no")
      |> send_chunked(200)

    relay(conn, task, tag, opts.keepalive)
  end

  defp relay(conn, task, tag, keepalive) do
    receive do
      {^tag, :progress, params} ->
        notification = %{
          "jsonrpc" => "2.0",
          "method" => "notifications/progress",
          "params" => params
        }

        continue(conn, task, tag, keepalive, sse_event(notification))

      {ref, {_status, body}} when ref == task.ref ->
        Process.demonitor(ref, [:flush])

        case chunk(conn, sse_event(body)) do
          {:ok, conn} -> conn
          {:error, _closed} -> conn
        end
    after
      keepalive -> continue(conn, task, tag, keepalive, ":\n\n")
    end
  end

  # A failed write means the client closed the stream: that is the cancellation.
  defp continue(conn, task, tag, keepalive, data) do
    case chunk(conn, data) do
      {:ok, conn} ->
        relay(conn, task, tag, keepalive)

      {:error, _reason} ->
        Task.shutdown(task, :brutal_kill)
        conn
    end
  end

  defp sse_event(message), do: ["event: message\ndata: ", Jason.encode!(message), "\n\n"]

  defp check_origin(conn, %{allowed_origins: allowed}) do
    case get_req_header(conn, "origin") do
      [] -> :ok
      [origin] -> if origin_allowed?(conn, origin, allowed), do: :ok, else: forbidden_origin(conn)
      _many -> forbidden_origin(conn)
    end
  end

  defp origin_allowed?(_conn, _origin, :any), do: true
  defp origin_allowed?(conn, origin, :same_origin), do: same_host?(conn, origin)

  defp origin_allowed?(conn, origin, allowed) when is_list(allowed),
    do: origin in allowed or same_host?(conn, origin)

  # The host, not the port: behind a proxy the app's port is not the public one.
  defp same_host?(conn, origin) do
    case URI.parse(origin) do
      %URI{host: host} when is_binary(host) -> String.downcase(host) == String.downcase(conn.host)
      _invalid -> false
    end
  end

  defp forbidden_origin(conn) do
    body = %{
      "jsonrpc" => "2.0",
      "error" => %{"code" => -32_600, "message" => "Origin not allowed"}
    }

    {:reply, 403, body, conn}
  end

  defp read_message(%Plug.Conn{body_params: %Plug.Conn.Unfetched{}} = conn) do
    {:ok, body, conn} = read_body(conn)

    case Jason.decode(body) do
      {:ok, message} -> {:ok, message, conn}
      {:error, _reason} -> parse_error(conn)
    end
  end

  # Plug.Parsers wraps a top-level JSON array (a batch) under "_json"; batches
  # are not part of the protocol and come back as Invalid Request.
  defp read_message(%Plug.Conn{body_params: %{"_json" => batch}} = conn), do: {:ok, batch, conn}
  defp read_message(%Plug.Conn{body_params: params} = conn), do: {:ok, params, conn}

  defp parse_error(conn) do
    {status, body} = Protocol.parse_error()
    {:reply, status, body, conn}
  end

  defp headers(conn) do
    %{
      protocol_version: header(conn, "mcp-protocol-version"),
      method: header(conn, "mcp-method"),
      name: conn |> header("mcp-name") |> decode_header_value()
    }
  end

  defp header(conn, name) do
    case get_req_header(conn, name) do
      [value | _] -> value
      [] -> nil
    end
  end

  defp decode_header_value("=?base64?" <> rest = value) do
    with true <- String.ends_with?(rest, "?="),
         {:ok, decoded} <- rest |> String.trim_trailing("?=") |> Base.decode64() do
      decoded
    else
      _invalid -> value
    end
  end

  defp decode_header_value(value), do: value

  defp send_json(conn, 202, nil), do: conn |> send_resp(202, "") |> halt()

  defp send_json(conn, status, body) do
    conn
    |> put_resp_content_type("application/json")
    |> send_resp(status, Jason.encode!(body))
    |> halt()
  end

  # Defaults are remote captures so `init/1` can run at compile time (Phoenix
  # router): anonymous functions cannot be escaped into compiled code.

  @doc false
  def current_client(conn), do: conn.assigns[:current_client]

  @doc false
  def client_name(%{name: name}), do: to_string(name)
  def client_name(_client), do: nil

  @doc false
  def no_assigns(_conn), do: %{}
end
