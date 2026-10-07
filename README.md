# AriadnaMCP

Stateless [Model Context Protocol](https://modelcontextprotocol.io) servers for Plug and Phoenix.

Every request is answered on its own, so any replica can serve any request: no
sessions to replicate and no sticky load balancing. One endpoint serves both
eras of the specification:

- **2026-07-28** (modern): per-request `_meta`, `server/discover`,
  `resultType`, mirrored HTTP headers validated against the body.
- **2025-03-26 to 2025-11-25** (legacy): `initialize`, then requests answered
  one by one, without a session.

What a product writes: a server module (`AriadnaMCP.Server`), tools
(`AriadnaMCP.Tool`) and a route to `AriadnaMCP.Plug` behind its own
authentication. Tools are `Jido.Action` modules (`AriadnaMCP.JidoAction`), or
carry their schema through an `AriadnaMCP.Schema.Adapter`, or use Peri schemas
(`AriadnaMCP.Schema`, optional `:peri` dependency). What it gets:

- argument validation against the advertised input schema;
- results projected onto the output schema (an allowlist of fields) and
  returned as `structuredContent`;
- write tools served only when the server enables them;
- per-scope authorization, with `tools/list` showing each client only what it
  may call, plus audit and telemetry hooks;
- progress over a request-scoped SSE stream, where closing the stream cancels
  the call;
- `AriadnaMCP.Testing` to drive a server like a client, including a `tools/list`
  snapshot for review.

## Usage

```elixir
defmodule MyApp.MCP do
  use AriadnaMCP.Server
  import AriadnaMCP.Schema

  @impl true
  def info, do: %{name: "MyApp", version: "1.0.0", instructions: "What MyApp answers."}

  @impl true
  def tools do
    [
      %AriadnaMCP.Tool{
        name: "search",
        description: "Search the library by text",
        scope: "read:library",
        input: object(%{"query" => string("Text to search")}, required: ["query"]),
        output: nullable(%{"items" => {:list, %{"title" => :string}}}),
        handler: {MyApp.MCP.Tools, :search}
      }
    ]
  end

  @impl true
  def authorize(%AriadnaMCP.Context{client: client}, scope),
    do: if(scope in client.scopes, do: :ok, else: {:error, "missing scope #{scope}"})

  def client_name(client), do: client.name
end

# router.ex, behind the pipeline that authenticates the client
scope "/api" do
  pipe_through :mcp
  forward "/mcp", AriadnaMCP.Plug, server: MyApp.MCP, client_name: &MyApp.MCP.client_name/1
end
```

A tool that raises, exits or returns a result that breaks its output schema is
reported through `report_exception/3` and answered with `internal_error/0`,
`"internal_error"` unless the server defines its own: a map goes out as
`structuredContent` with `isError`, a string as text.

```elixir
@impl true
def internal_error, do: %{"error" => "operation_failed"}
```

## Jido actions as tools

With `jido_action` installed, a `Jido.Action` is served as an MCP tool, so one
action backs an in-process agent (`jido_ai`), the MCP server and the UI:

```elixir
def tools do
  [
    AriadnaMCP.JidoAction.tool(MyApp.Actions.SearchLibrary,
      scope: "read:library",
      context: &MyApp.MCP.action_context/1
    )
  ]
end
```

MCP arguments arrive with string keys and are converted to the schema's atom
keys before validation. Results are projected onto the action's
`output_schema` by AriadnaMCP itself: Jido lets undeclared top-level keys
through. Declare output schemas with Zoi to strip undeclared fields at every
depth.

## Interoperability

The test suite runs a real MCP client (ExMCP) against `AriadnaMCP.Plug` over
HTTP in both eras.

## Status

Used by Balneario de Cofrentes and DjinnFoundry products. The source is public;
it is not yet released under an open-source license.
