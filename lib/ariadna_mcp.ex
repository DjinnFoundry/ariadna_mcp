defmodule AriadnaMCP do
  @moduledoc """
  Stateless [Model Context Protocol](https://modelcontextprotocol.io) servers
  for Plug and Phoenix.

  Every request is answered on its own, so any replica can serve any request:
  no sessions to replicate, no sticky load balancing. Both eras of the
  specification are served from one endpoint: modern clients (2026-07-28,
  per-request `_meta`, `server/discover`) and legacy clients (2025-03-26 to
  2025-11-25, starting with `initialize`).

  A product provides:

    * a server module implementing `AriadnaMCP.Server` (info, tools,
      authorization and, optionally, resources, prompts, audit and the write
      tools it serves);
    * tools as `AriadnaMCP.Tool` structs with Peri schemas from
      `AriadnaMCP.Schema`: input schemas validate arguments, output schemas are
      the allowlist results are projected onto;
    * a route to `AriadnaMCP.Plug` behind its own authentication.

  Long tools can report progress with `AriadnaMCP.Context.progress/3`; the
  response then streams as SSE and closing the stream cancels the call.
  `AriadnaMCP.Testing` drives a server like a client in tests.
  """

  defdelegate handle(server, message, context, headers \\ nil), to: AriadnaMCP.Protocol
end
