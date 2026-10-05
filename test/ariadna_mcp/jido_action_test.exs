defmodule AriadnaMCP.JidoActionTest do
  use ExUnit.Case, async: true

  import AriadnaMCP.Testing

  alias AriadnaMCP.JidoServer

  @reader %{name: "reader", scopes: ["read"]}

  defp tool(name),
    do:
      JidoServer
      |> result!("tools/list")
      |> Map.fetch!("tools")
      |> Enum.find(&(&1["name"] == name))

  test "advertises action names, descriptions and JSON Schemas from Zoi and NimbleOptions" do
    search = tool("search_library")
    assert search["description"] == "Search the library by text"
    assert search["inputSchema"]["required"] == ["query"]

    assert search["inputSchema"]["properties"]["query"] == %{
             "type" => "string",
             "description" => "Text to search"
           }

    refute Map.has_key?(search["inputSchema"], "$schema")
    assert search["outputSchema"]["properties"]["items"]["type"] == "array"

    quarter = tool("inspect_quarter")
    assert quarter["title"] == "Quarter"
    assert Enum.sort(quarter["inputSchema"]["required"]) == ["quarter", "year"]
    assert quarter["outputSchema"]["properties"]["status"]

    refute Map.has_key?(tool("failing"), "outputSchema")
  end

  test "runs an action from string-keyed arguments and projects the result at every depth" do
    result =
      call_tool!(
        JidoServer,
        "search_library",
        %{"query" => "acogida", "limit" => 2, "extra" => 1},
        client: @reader
      )

    assert result["isError"] == false

    assert result["structuredContent"] == %{
             "items" => [%{"title" => "acogida x2", "note" => nil}]
           }

    refute hd(result["content"])["text"] =~ "hidden"
    refute hd(result["content"])["text"] =~ "internal"
  end

  test "passes the host context to the action" do
    defmodule Echo do
      @moduledoc false
      use Jido.Action, name: "echo_context", description: "Echoes its context"
      @impl true
      def run(_params, context), do: {:ok, %{client: context[:mcp].client_name}}
    end

    tool = AriadnaMCP.JidoAction.tool(Echo)

    assert {:ok, %{client: "reader"}} =
             AriadnaMCP.Tool.run(tool, %{}, %AriadnaMCP.Context{client_name: "reader"})
  end

  test "NimbleOptions schemas validate input and project the top level" do
    assert %{"structuredContent" => %{"status" => "2026-Q3 open"}} =
             call_tool!(JidoServer, "inspect_quarter", %{"year" => 2026, "quarter" => 3})

    assert {200, %{"error" => %{"code" => -32_602, "message" => message}}} =
             call(
               JidoServer,
               request("tools/call", %{
                 "name" => "inspect_quarter",
                 "arguments" => %{"year" => 2026}
               })
             )

    assert message =~ "quarter"
  end

  test "invalid Zoi arguments are a protocol error" do
    assert {200, %{"error" => %{"code" => -32_602, "message" => message}}} =
             call(
               JidoServer,
               request("tools/call", %{
                 "name" => "search_library",
                 "arguments" => %{"limit" => "x"}
               }),
               client: @reader
             )

    assert message =~ "query"
  end

  test "action errors become tool errors and scopes still apply" do
    assert %{"isError" => true, "content" => [%{"text" => "the ledger is locked"}]} =
             call_tool!(JidoServer, "failing")

    assert %{"isError" => true, "content" => [%{"text" => "client lacks scope read"}]} =
             call_tool!(JidoServer, "search_library", %{"query" => "x"},
               client: %{name: "nobody", scopes: []}
             )
  end

  test "a result that breaks a Zoi output schema is an internal error" do
    defmodule Broken do
      @moduledoc false
      use Jido.Action,
        name: "broken",
        description: "Breaks its output schema",
        output_schema: Zoi.object(%{count: Zoi.integer()})

      @impl true
      def run(_params, _context), do: {:ok, %{count: 1}}
    end

    assert {:error, _message} =
             AriadnaMCP.JidoAction.project(Broken.output_schema(), %{count: "many"})

    assert {:ok, %{"count" => 1}} =
             AriadnaMCP.JidoAction.project(Broken.output_schema(), %{count: 1, extra: true})
  end
end
