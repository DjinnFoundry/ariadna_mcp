defmodule AriadnaMCP.InteropTest do
  @moduledoc """
  A real MCP client (ExMCP) against `AriadnaMCP.Plug` over HTTP, in both eras:
  our tests check the specification as we read it, this checks it against an
  independent implementation.
  """
  use ExUnit.Case, async: false

  setup_all do
    {:ok, _apps} = Application.ensure_all_started(:ex_mcp)
    :ok
  end

  setup do
    server =
      start_supervised!(
        {Bandit, plug: AriadnaMCP.InteropRouter, port: 0, ip: :loopback, startup_log: false}
      )

    {:ok, {_ip, port}} = ThousandIsland.listener_info(server)
    {:ok, url: "http://127.0.0.1:#{port}/mcp"}
  end

  for {mode, version} <- [modern_only: "2026-07-28", legacy_only: "2025-11-25"] do
    test "#{mode}: negotiates #{version}, lists, calls and gets protocol errors", %{url: url} do
      {:ok, client} =
        ExMCP.Client.start_link(
          transport: :http,
          url: url,
          protocol_mode: unquote(mode),
          reconnect: false,
          health_check_interval: 0
        )

      on_exit(fn -> if Process.alive?(client), do: ExMCP.Client.stop(client) end)

      assert {:ok, unquote(version)} = ExMCP.Client.negotiated_version(client)

      assert {:ok, %ExMCP.Response{tools: tools} = list} = ExMCP.Client.list_tools(client)
      names = Enum.map(tools, &(&1["name"] || &1[:name]))
      assert "echo" in names
      refute "write_note" in names

      if unquote(mode) == :modern_only do
        assert list.ttlMs == 300_000 and list.cacheScope == "public"
      end

      assert {:ok, %ExMCP.Response{} = result} =
               ExMCP.Client.call_tool(client, "echo", %{"text" => "hola", "times" => 2})

      refute result.is_error

      assert %{"note" => %{"text" => "hola", "times" => 2}} =
               Jason.decode!(ExMCP.Response.text_content(result))

      assert {:error, %{code: -32_602, message: message}} =
               ExMCP.Client.call_tool(client, "echo", %{})

      assert message =~ "text"
    end
  end

  test "prefer_modern picks the modern era", %{url: url} do
    {:ok, client} =
      ExMCP.Client.start_link(
        transport: :http,
        url: url,
        protocol_mode: :prefer_modern,
        reconnect: false,
        health_check_interval: 0
      )

    on_exit(fn -> if Process.alive?(client), do: ExMCP.Client.stop(client) end)
    assert {:ok, "2026-07-28"} = ExMCP.Client.negotiated_version(client)
  end
end
