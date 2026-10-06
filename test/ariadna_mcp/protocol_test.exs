defmodule AriadnaMCP.ProtocolTest do
  use ExUnit.Case, async: false

  import AriadnaMCP.Testing

  alias AriadnaMCP.{Context, Protocol, TestServer}

  @reader %{name: "reader", scopes: ["read"]}
  @writer %{name: "writer", scopes: ["read", "write"]}

  setup do
    Application.put_env(:ariadna_mcp, :test_pid, self())

    on_exit(fn ->
      Application.delete_env(:ariadna_mcp, :test_pid)
      Application.delete_env(:ariadna_mcp, :enabled_write_tools)
    end)
  end

  defp legacy(method, params \\ %{}), do: request(method, params, version: "2025-06-18")

  describe "legacy clients (2025)" do
    test "initialize negotiates a known version and needs no session afterwards" do
      assert {200, %{"result" => result}} =
               call(TestServer, legacy("initialize", %{"protocolVersion" => "2025-06-18"}))

      assert result["protocolVersion"] == "2025-06-18"
      assert result["serverInfo"] == %{"name" => "Test", "version" => "1.2.3"}
      assert result["instructions"] == "Use the test tools."
      assert result["capabilities"]["resources"] && result["capabilities"]["prompts"]
      refute Map.has_key?(result, "resultType")

      assert {200, %{"result" => %{"protocolVersion" => "2025-11-25"}}} =
               call(TestServer, legacy("initialize", %{"protocolVersion" => "1999-01-01"}))

      assert {200, %{"result" => %{"tools" => [_ | _]}}} = call(TestServer, legacy("tools/list"))
      assert {200, %{"result" => %{}}} = call(TestServer, legacy("ping"))
    end

    test "unknown methods answer Method not found with 200" do
      assert {200, %{"error" => %{"code" => -32_601}}} = call(TestServer, legacy("nope"))
    end
  end

  describe "modern clients (2026-07-28)" do
    test "server/discover advertises versions, capabilities and identity" do
      assert {200, %{"result" => result}} = call(TestServer, request("server/discover"))
      assert result["supportedVersions"] == Protocol.supported_versions()
      assert "2026-07-28" in result["supportedVersions"]
      assert result["resultType"] == "complete"

      assert result["_meta"]["io.modelcontextprotocol/serverInfo"] == %{
               "name" => "Test",
               "version" => "1.2.3"
             }

      assert result["instructions"] == "Use the test tools."
      assert %{"ttlMs" => _, "cacheScope" => "public", "capabilities" => %{"tools" => _}} = result
    end

    test "cacheable results carry ttlMs and cacheScope; legacy results do not" do
      for method <- ~w(prompts/list resources/list resources/templates/list) do
        assert %{"ttlMs" => 300_000, "cacheScope" => "public"} = result!(TestServer, method),
               method
      end

      # tools/list depends on the client's scopes.
      assert %{"ttlMs" => 300_000, "cacheScope" => "private"} = result!(TestServer, "tools/list")

      assert %{"ttlMs" => 0, "cacheScope" => "private"} =
               result!(TestServer, "resources/read", %{"uri" => "note://1"}, client: @reader)

      refute Map.has_key?(call_tool!(TestServer, "plain"), "ttlMs")
      assert {200, %{"result" => legacy}} = call(TestServer, legacy("tools/list"))
      refute Map.has_key?(legacy, "ttlMs")
    end

    test "every result carries resultType and serverInfo" do
      assert %{
               "resultType" => "complete",
               "_meta" => %{"io.modelcontextprotocol/serverInfo" => _}
             } =
               result!(TestServer, "tools/list")
    end

    test "rejects unsupported versions with -32022 and the supported list" do
      message =
        request("tools/list", %{
          "_meta" => %{"io.modelcontextprotocol/protocolVersion" => "2027-01-01"}
        })

      assert {400, %{"error" => %{"code" => -32_022, "data" => data}}} = call(TestServer, message)
      assert data == %{"supported" => Protocol.supported_versions(), "requested" => "2027-01-01"}
    end

    test "removed legacy methods are unknown and answer 404" do
      assert {404, %{"error" => %{"code" => -32_601}}} = call(TestServer, request("ping"))
      assert {404, %{"error" => %{"code" => -32_601}}} = call(TestServer, request("initialize"))
    end
  end

  describe "HTTP header validation (modern)" do
    defp headers(overrides \\ %{}),
      do:
        Map.merge(
          %{protocol_version: "2026-07-28", method: "tools/call", name: "echo"},
          overrides
        )

    defp http(message, headers) do
      Protocol.handle(
        TestServer,
        message,
        %Context{client: @reader, client_name: "reader"},
        headers
      )
    end

    test "accepts matching headers" do
      message = request("tools/call", %{"name" => "echo", "arguments" => %{"text" => "hi"}})
      assert {200, %{"result" => %{"isError" => false}}} = http(message, headers())
    end

    test "rejects missing or mismatched headers with -32020 and 400" do
      message = request("tools/call", %{"name" => "echo", "arguments" => %{"text" => "hi"}})

      for bad <- [
            %{protocol_version: nil},
            %{protocol_version: "2025-11-25"},
            %{method: "tools/list"},
            %{method: nil},
            %{name: "other"},
            %{name: nil}
          ] do
        assert {400, %{"error" => %{"code" => -32_020, "message" => "Header mismatch: " <> _}}} =
                 http(message, headers(bad)),
               inspect(bad)
      end
    end

    test "rejects a modern header with a body that has no version in _meta" do
      message = legacy("tools/list")

      assert {400, %{"error" => %{"code" => -32_020}}} =
               http(message, headers(%{method: "tools/list", name: nil}))
    end

    test "rejects an unknown version header from a legacy-looking body" do
      assert {400, %{"error" => %{"code" => -32_022}}} =
               http(legacy("tools/list"), %{
                 protocol_version: "2030-01-01",
                 method: nil,
                 name: nil
               })
    end
  end

  describe "tools" do
    test "tools/list serves read tools and only the enabled write tools" do
      names = fn ->
        TestServer
        |> result!("tools/list", %{}, client: @writer)
        |> Map.fetch!("tools")
        |> Enum.map(& &1["name"])
      end

      refute "write_note" in names.()
      Application.put_env(:ariadna_mcp, :enabled_write_tools, ["write_note"])
      assert "write_note" in names.()
      Application.put_env(:ariadna_mcp, :enabled_write_tools, :all)
      assert "write_note" in names.()
    end

    test "tools/list hides the tools the client's scopes do not allow" do
      Application.put_env(:ariadna_mcp, :enabled_write_tools, :all)

      names = fn client ->
        TestServer
        |> result!("tools/list", %{}, client: client)
        |> Map.fetch!("tools")
        |> Enum.map(& &1["name"])
      end

      assert "echo" in names.(@reader)
      refute "write_note" in names.(@reader)
      refute "admin_only" in names.(@reader)
      assert "write_note" in names.(@writer)
      assert "admin_only" in names.(%{name: "admin", scopes: ["admin"]})

      unscoped = names.(nil)
      assert "plain" in unscoped
      refute "echo" in unscoped

      # Listing is not an access attempt.
      refute_received {:audit, :scope_denied, _, _, _}
    end

    test "advertises input and output schemas as JSON Schema" do
      echo =
        TestServer
        |> result!("tools/list", %{}, client: @reader)
        |> Map.fetch!("tools")
        |> Enum.find(&(&1["name"] == "echo"))

      assert echo["inputSchema"]["required"] == ["text"]

      assert echo["inputSchema"]["properties"]["text"] == %{
               "type" => "string",
               "description" => "Text to echo"
             }

      assert %{"properties" => %{"note" => %{"oneOf" => [_, %{"type" => "null"}]}}} =
               echo["outputSchema"]
    end

    test "projects results onto the output schema and returns structuredContent" do
      result =
        call_tool!(TestServer, "echo", %{"text" => "hola", "times" => 2, "undeclared" => 1},
          client: @reader
        )

      assert result["structuredContent"] == %{"note" => %{"text" => "hola", "times" => 2}}
      assert Jason.decode!(hd(result["content"])["text"]) == result["structuredContent"]
      assert result["isError"] == false

      assert_received {:audit, :tool_called, "echo", "reader",
                       %{params: %{"keys" => ["text", "times"]}}}
    end

    test "returns text when a tool has no output schema" do
      assert %{"content" => [%{"type" => "text", "text" => "plain text"}], "isError" => false} =
               result = call_tool!(TestServer, "plain")

      refute Map.has_key?(result, "structuredContent")
    end

    test "returns structuredContent for an object result without an output schema" do
      result = call_tool!(TestServer, "unschemed")

      assert result["structuredContent"] == %{"count" => 2, "items" => ["a", "b"]}
      assert Jason.decode!(hd(result["content"])["text"]) == result["structuredContent"]
      assert result["isError"] == false
    end

    test "a structured error is returned as structuredContent with isError" do
      result = call_tool!(TestServer, "fails_structured")

      assert result["isError"] == true
      assert result["structuredContent"] == %{"error" => "invalid_quarter", "quarter" => 8}
      assert Jason.decode!(hd(result["content"])["text"]) == result["structuredContent"]
    end

    test "invalid arguments are a protocol error" do
      assert {200, %{"error" => %{"code" => -32_602, "message" => message}}} =
               call(TestServer, request("tools/call", %{"name" => "echo", "arguments" => %{}}),
                 client: @reader
               )

      assert message =~ "text"

      assert {200, %{"error" => %{"code" => -32_602}}} =
               call(TestServer, request("tools/call", %{"name" => "echo", "arguments" => "nope"}),
                 client: @reader
               )
    end

    test "unknown or disabled tools are a protocol error" do
      assert {200, %{"error" => %{"code" => -32_602, "message" => "Tool not found: missing"}}} =
               call(TestServer, request("tools/call", %{"name" => "missing"}))

      assert {200, %{"error" => %{"message" => "Tool not found: write_note"}}} =
               call(TestServer, request("tools/call", %{"name" => "write_note"}), client: @writer)
    end

    test "a denied scope is a tool error and is audited" do
      assert %{"isError" => true, "content" => [%{"text" => "client lacks scope admin"}]} =
               call_tool!(TestServer, "admin_only", %{}, client: @reader)

      assert_received {:audit, :scope_denied, "admin_only", "reader",
                       %{reason: "client lacks scope admin"}}
    end

    test "domain errors, exceptions and broken outputs become tool errors" do
      assert %{"isError" => true, "content" => [%{"text" => "not today"}]} =
               call_tool!(TestServer, "fails")

      assert %{"isError" => true, "content" => [%{"text" => "internal_error"}]} =
               call_tool!(TestServer, "boom")

      assert_received {:exception, "kaboom", %{context: "mcp_tool", tool: "boom"}}

      assert %{"isError" => true, "content" => [%{"text" => "internal_error"}]} =
               call_tool!(TestServer, "bad_output")

      assert_received {:exception, "MCP tool result does not match its output schema" <> _,
                       %{tool: "bad_output"}}
    end

    test "emits telemetry under the server's prefix" do
      handler = "telemetry-#{System.unique_integer([:positive])}"
      pid = self()

      :telemetry.attach_many(
        handler,
        [
          [:test_mcp, :tool_call, :start],
          [:test_mcp, :tool_call, :stop],
          [:test_mcp, :tool_call, :exception]
        ],
        fn event, measurements, metadata, _config ->
          send(pid, {:telemetry, event, measurements, metadata})
        end,
        nil
      )

      on_exit(fn -> :telemetry.detach(handler) end)

      call_tool!(TestServer, "echo", %{"text" => "x"}, client: @reader)

      assert_received {:telemetry, [:test_mcp, :tool_call, :start], _,
                       %{tool: "echo", client_name: "reader"}}

      assert_received {:telemetry, [:test_mcp, :tool_call, :stop], %{duration: duration},
                       %{status: :ok}}

      assert duration >= 0

      call_tool!(TestServer, "boom")
      assert_received {:telemetry, [:test_mcp, :tool_call, :exception], _, %{kind: :error}}

      call_tool!(TestServer, "badarg")

      assert_received {:telemetry, [:test_mcp, :tool_call, :exception], _,
                       %{stacktrace: stacktrace}}

      refute inspect(stacktrace) =~ "secret-argument"

      # Frames keep their arity, never the arguments a call carried.
      assert Enum.all?(stacktrace, fn {_m, _f, arity, _location} -> is_integer(arity) end)
    end
  end

  describe "resources" do
    test "lists templates and reads authorized resources" do
      assert %{
               "resourceTemplates" => [
                 %{"uriTemplate" => "note://{id}", "mimeType" => "application/json"}
               ]
             } =
               result!(TestServer, "resources/templates/list")

      assert %{"resources" => []} = result!(TestServer, "resources/list")

      assert %{"contents" => [%{"uri" => "note://7", "text" => text}]} =
               result!(TestServer, "resources/read", %{"uri" => "note://7"}, client: @reader)

      assert Jason.decode!(text) == %{"id" => "7", "text" => "hello"}
      assert_received {:audit, :resource_read, "note://7", "reader", %{}}
    end

    test "denied, unknown and failing reads answer -32002" do
      for {uri, client} <- [
            {"note://7", %{name: "nobody", scopes: []}},
            {"other://1", @reader},
            {"note://missing", @reader}
          ] do
        assert {200, %{"error" => %{"code" => -32_002}}} =
                 call(TestServer, request("resources/read", %{"uri" => uri}), client: client),
               uri
      end
    end
  end

  describe "prompts" do
    test "renders authorized prompts" do
      assert %{
               "prompts" => [
                 %{"name" => "summarize", "arguments" => [%{"name" => "id", "required" => true}]}
                 | _
               ]
             } =
               result!(TestServer, "prompts/list")

      assert %{
               "description" => "Summarize a note",
               "messages" => [%{"role" => "user", "content" => %{"text" => "Summarize note 3"}}]
             } =
               result!(
                 TestServer,
                 "prompts/get",
                 %{"name" => "summarize", "arguments" => %{"id" => "3"}},
                 client: @reader
               )
    end

    test "unknown, denied and failing prompts answer -32602" do
      for {name, client} <- [
            {"missing", @reader},
            {"summarize", %{name: "nobody", scopes: []}},
            {"broken", @reader}
          ] do
        assert {200, %{"error" => %{"code" => -32_602}}} =
                 call(TestServer, request("prompts/get", %{"name" => name}), client: client),
               name
      end
    end
  end

  describe "a server without prompts or resources" do
    defmodule ToolsOnly do
      @moduledoc false
      use AriadnaMCP.Server
      @impl true
      def info, do: %{name: "ToolsOnly", version: "0"}
      @impl true
      def tools, do: []
      @impl true
      def authorize(_context, _scope), do: :ok
    end

    test "answers Method not found for the capabilities it does not offer" do
      for method <-
            ~w(prompts/list prompts/get resources/list resources/templates/list resources/read) do
        assert {404, %{"error" => %{"code" => -32_601}}} =
                 call(ToolsOnly, request(method, %{"name" => "x", "uri" => "x://1"})),
               method

        assert {200, %{"error" => %{"code" => -32_601, "message" => "Method not found"}}} =
                 call(ToolsOnly, legacy(method, %{"name" => "x", "uri" => "x://1"})),
               method
      end

      assert %{"capabilities" => capabilities} = result!(ToolsOnly, "server/discover")
      assert Map.keys(capabilities) == ["tools"]
    end
  end

  describe "messages" do
    test "notifications are accepted without a body" do
      assert {202, nil} =
               call(TestServer, %{"jsonrpc" => "2.0", "method" => "notifications/initialized"})
    end

    test "malformed messages answer Invalid Request" do
      assert {200, %{"error" => %{"code" => -32_600}}} = call(TestServer, [%{"jsonrpc" => "2.0"}])

      assert {200, %{"error" => %{"code" => -32_600}}} =
               call(TestServer, %{"id" => 1, "method" => "tools/list"})

      assert {200, %{"error" => %{"code" => -32_602}}} =
               call(TestServer, request("tools/call", %{}))

      for method <- ~w(tools/call prompts/get) do
        assert {200, %{"error" => %{"code" => -32_602, "message" => "Invalid params"}}} =
                 call(TestServer, request(method, %{"name" => %{"a" => 1}}), client: @reader),
               method
      end
    end
  end
end
