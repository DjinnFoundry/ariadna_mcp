# AriadnaMCP

Stateless [Model Context Protocol](https://modelcontextprotocol.io) servers for Plug and Phoenix.

Every request is answered on its own, so any replica can serve any request: no
sessions to replicate and no sticky load balancing. One endpoint serves both
eras of the specification:

- **2026-07-28** (modern): per-request `_meta`, `server/discover`,
  `resultType`, mirrored HTTP headers validated against the body.
- **2025-03-26 to 2025-11-25** (legacy): `initialize`, then requests answered
  one by one, without a session.

What a product writes: a server module (`AriadnaMCP.Server`), tools with Peri
schemas (`AriadnaMCP.Tool`, `AriadnaMCP.Schema`) and a route to
`AriadnaMCP.Plug` behind its own authentication. What it gets:

- argument validation against the advertised input schema;
- results projected onto the output schema (an allowlist of fields) and
  returned as `structuredContent`;
- write tools served only when the server enables them;
- per-scope authorization, audit and telemetry hooks;
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

## Status

Private, used by Balneario de Cofrentes and DjinnFoundry products. Not yet
released under an open-source license.
