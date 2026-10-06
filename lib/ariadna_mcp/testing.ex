defmodule AriadnaMCP.Testing do
  @moduledoc """
  Helpers for testing a server the way a client uses it.

      test "tools/list matches the snapshot" do
        assert AriadnaMCP.Testing.snapshot(MyApp.MCP, client: admin) == File.read!("test/support/mcp_tools.json")
      end

      test "search returns only declared fields" do
        result = AriadnaMCP.Testing.call_tool!(MyApp.MCP, "search", %{"query" => "x"}, client: client)
        assert result["structuredContent"]["items"]
      end

  Requests are modern (2026-07-28) unless `version:` says otherwise, and go
  through negotiation and dispatch like an HTTP request, minus the headers.
  """

  alias AriadnaMCP.{Context, Protocol}

  @modern "2026-07-28"

  @doc "A JSON-RPC request map, with the protocol version in `_meta` for modern versions."
  @spec request(String.t(), map(), keyword()) :: map()
  def request(method, params \\ %{}, opts \\ []) do
    version = Keyword.get(opts, :version, @modern)
    params = if version == @modern, do: put_meta(params, opts), else: params

    %{
      "jsonrpc" => "2.0",
      "id" => Keyword.get(opts, :id, 1),
      "method" => method,
      "params" => params
    }
  end

  @doc """
  Sends one message to a server and returns `{status, response}` as a client
  would receive it (after a JSON round trip).
  """
  @spec call(module(), map(), keyword()) :: {pos_integer(), map() | nil}
  def call(server, message, opts \\ []) do
    client = Keyword.get(opts, :client)

    context = %Context{
      client: client,
      client_name: Keyword.get(opts, :client_name, client_name(client)),
      assigns: Keyword.get(opts, :assigns, %{}),
      progress_fun: Keyword.get(opts, :progress_fun)
    }

    case Protocol.handle(server, message, context) do
      {status, nil} -> {status, nil}
      {status, body} -> {status, body |> Jason.encode!() |> Jason.decode!()}
    end
  end

  @doc "The `result` of a method call; fails on a JSON-RPC error."
  @spec result!(module(), String.t(), map(), keyword()) :: map()
  def result!(server, method, params \\ %{}, opts \\ []) do
    case call(server, request(method, params, opts), opts) do
      {_status, %{"result" => result}} ->
        result

      {status, other} ->
        raise "expected a result from #{method}, got #{status}: #{inspect(other)}"
    end
  end

  @doc "Calls a tool and returns its result (`content`, `structuredContent`, `isError`)."
  @spec call_tool!(module(), String.t(), map(), keyword()) :: map()
  def call_tool!(server, name, arguments \\ %{}, opts \\ []),
    do: result!(server, "tools/call", %{"name" => name, "arguments" => arguments}, opts)

  @doc """
  The `tools/list` served to a client (`client:`, as in `call/3`) as pretty
  JSON with sorted keys, for a versioned snapshot: a changed description or
  schema changes what agents do and should show up in review. The list holds
  only the tools the client's scopes allow, so snapshot with a client that
  holds every scope.
  """
  @spec snapshot(module(), keyword()) :: String.t()
  def snapshot(server, opts \\ []) do
    server
    |> result!("tools/list", %{}, opts)
    |> Map.fetch!("tools")
    |> sort_keys()
    |> Jason.encode!(pretty: true)
  end

  @doc """
  Paths in `value` that the JSON Schema does not declare. A projected result
  should always return `[]`.
  """
  @spec undeclared_paths(term(), map()) :: [String.t()]
  def undeclared_paths(nil, _schema), do: []

  def undeclared_paths(value, %{"oneOf" => branches}), do: undeclared_in_branches(value, branches)
  def undeclared_paths(value, %{"anyOf" => branches}), do: undeclared_in_branches(value, branches)

  def undeclared_paths(value, %{"type" => "array", "items" => items}) when is_list(value),
    do: Enum.flat_map(value, &undeclared_paths(&1, items))

  def undeclared_paths(value, %{"properties" => properties}) when is_map(value) do
    Enum.flat_map(value, fn {key, nested} ->
      case properties do
        %{^key => schema} -> Enum.map(undeclared_paths(nested, schema), &"#{key}.#{&1}")
        _undeclared -> [key]
      end
    end)
  end

  def undeclared_paths(_value, _schema), do: []

  # Nullable fields: Peri advertises oneOf, Zoi anyOf; check the non-null branch.
  defp undeclared_in_branches(value, branches),
    do: undeclared_paths(value, Enum.find(branches, &(&1["type"] != "null")))

  defp put_meta(params, opts) do
    meta =
      %{
        "io.modelcontextprotocol/protocolVersion" => @modern,
        "io.modelcontextprotocol/clientCapabilities" => %{}
      }
      |> then(
        &if token = opts[:progress_token], do: Map.put(&1, "progressToken", token), else: &1
      )

    Map.update(params, "_meta", meta, &Map.merge(meta, &1))
  end

  defp client_name(%{name: name}), do: to_string(name)
  defp client_name(_client), do: nil

  # JSON Schema's "required" is a set; some schema libraries emit it in map
  # order, which varies between compilations.
  defp sort_keys(map) when is_map(map) do
    map
    |> Enum.sort_by(&elem(&1, 0))
    |> Enum.map(fn
      {"required", list} when is_list(list) -> {"required", Enum.sort(list)}
      {key, value} -> {key, sort_keys(value)}
    end)
    |> Jason.OrderedObject.new()
  end

  defp sort_keys(list) when is_list(list), do: Enum.map(list, &sort_keys/1)
  defp sort_keys(other), do: other
end
