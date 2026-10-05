defmodule AriadnaMCP.InteropRouter do
  @moduledoc false
  use Plug.Router

  plug(:match)
  plug(:assign_client)
  plug(:dispatch)

  forward("/mcp", to: AriadnaMCP.Plug, init_opts: [server: AriadnaMCP.TestServer])

  def assign_client(conn, _opts),
    do: Plug.Conn.assign(conn, :current_client, %{name: "exmcp", scopes: ["read", "write"]})
end
