defmodule AriadnaMCP.PlugTest do
  use ExUnit.Case, async: false

  import Plug.Conn
  import Plug.Test

  alias AriadnaMCP.{ClosingAdapter, TestServer}

  @reader %{name: "reader", scopes: ["read"]}
  @opts AriadnaMCP.Plug.init(server: TestServer)

  setup do
    Application.put_env(:ariadna_mcp, :test_pid, self())
    on_exit(fn -> Application.delete_env(:ariadna_mcp, :test_pid) end)
  end

  defp post_message(message, headers \\ [], opts \\ @opts) do
    conn(:post, "/mcp", Jason.encode!(message))
    |> put_req_header("content-type", "application/json")
    |> then(fn conn ->
      Enum.reduce(headers, conn, fn {k, v}, acc -> put_req_header(acc, k, v) end)
    end)
    |> assign(:current_client, @reader)
    |> AriadnaMCP.Plug.call(opts)
  end

  defp modern(method, params, extra_meta \\ %{}) do
    meta =
      Map.merge(
        %{
          "io.modelcontextprotocol/protocolVersion" => "2026-07-28",
          "io.modelcontextprotocol/clientCapabilities" => %{}
        },
        extra_meta
      )

    %{
      "jsonrpc" => "2.0",
      "id" => 1,
      "method" => method,
      "params" => Map.put(params, "_meta", meta)
    }
  end

  defp modern_headers(method, name \\ nil) do
    [{"mcp-protocol-version", "2026-07-28"}, {"mcp-method", method}] ++
      if(name, do: [{"mcp-name", name}], else: [])
  end

  test "answers a modern request as JSON" do
    message = modern("tools/call", %{"name" => "echo", "arguments" => %{"text" => "hi"}})
    conn = post_message(message, modern_headers("tools/call", "echo"))

    assert conn.status == 200
    assert ["application/json" <> _] = get_resp_header(conn, "content-type")

    assert %{"result" => %{"structuredContent" => %{"note" => %{"text" => "hi"}}}} =
             Jason.decode!(conn.resp_body)
  end

  test "serves legacy clients without headers or session" do
    conn =
      post_message(%{"jsonrpc" => "2.0", "id" => 1, "method" => "initialize", "params" => %{}})

    assert %{"result" => %{"protocolVersion" => "2025-11-25"}} = Jason.decode!(conn.resp_body)
    assert get_resp_header(conn, "mcp-session-id") == []
  end

  test "validates mirrored headers over HTTP, decoding base64 names" do
    message = modern("tools/call", %{"name" => "echo", "arguments" => %{"text" => "hi"}})

    assert post_message(
             message,
             modern_headers("tools/call", "=?base64?#{Base.encode64("echo")}?=")
           ).status == 200

    conn = post_message(message, modern_headers("tools/call", "other"))
    assert conn.status == 400
    assert %{"error" => %{"code" => -32_020}} = Jason.decode!(conn.resp_body)
  end

  test "unknown modern methods answer 404 and notifications 202" do
    conn = post_message(modern("nope", %{}), modern_headers("nope"))
    assert conn.status == 404

    conn = post_message(%{"jsonrpc" => "2.0", "method" => "notifications/initialized"})
    assert conn.status == 202
    assert conn.resp_body == ""
  end

  test "GET and DELETE answer 405 with Allow: POST" do
    for method <- [:get, :delete] do
      conn = conn(method, "/mcp") |> AriadnaMCP.Plug.call(@opts)
      assert conn.status == 405
      assert get_resp_header(conn, "allow") == ["POST"]
    end
  end

  test "rejects origins that are not allowed" do
    message = %{"jsonrpc" => "2.0", "id" => 1, "method" => "initialize", "params" => %{}}

    assert post_message(message, [{"origin", "https://evil.example"}]).status == 403

    allowed = AriadnaMCP.Plug.init(server: TestServer, allowed_origins: ["https://app.example"])
    assert post_message(message, [{"origin", "https://app.example"}], allowed).status == 200

    any = AriadnaMCP.Plug.init(server: TestServer, allowed_origins: :any)
    assert post_message(message, [{"origin", "https://evil.example"}], any).status == 200
  end

  test "answers a parse error for invalid JSON and Invalid Request for batches" do
    conn = conn(:post, "/mcp", "{not json") |> AriadnaMCP.Plug.call(@opts)
    assert conn.status == 400
    assert %{"error" => %{"code" => -32_700}} = Jason.decode!(conn.resp_body)

    batch =
      conn(:post, "/mcp", "") |> Map.put(:body_params, %{"_json" => [%{"jsonrpc" => "2.0"}]})

    assert %{"error" => %{"code" => -32_600}} =
             batch |> AriadnaMCP.Plug.call(@opts) |> Map.get(:resp_body) |> Jason.decode!()
  end

  test "uses already parsed body params from Plug.Parsers" do
    conn =
      conn(:post, "/mcp", "")
      |> Map.put(:body_params, %{
        "jsonrpc" => "2.0",
        "id" => 1,
        "method" => "initialize",
        "params" => %{}
      })
      |> AriadnaMCP.Plug.call(@opts)

    assert %{"result" => %{"serverInfo" => %{"name" => "Test"}}} = Jason.decode!(conn.resp_body)
  end

  test "streams progress as SSE when the client asks for it" do
    message =
      modern("tools/call", %{"name" => "slow", "arguments" => %{"steps" => 2}}, %{
        "progressToken" => "p1"
      })

    headers =
      modern_headers("tools/call", "slow") ++ [{"accept", "application/json, text/event-stream"}]

    conn = post_message(message, headers)

    assert conn.status == 200
    assert ["text/event-stream" <> _] = get_resp_header(conn, "content-type")
    assert get_resp_header(conn, "x-accel-buffering") == ["no"]

    events =
      conn.resp_body
      |> String.split("\n\n", trim: true)
      |> Enum.map(fn "event: message\ndata: " <> json -> Jason.decode!(json) end)

    assert [
             %{
               "method" => "notifications/progress",
               "params" => %{
                 "progressToken" => "p1",
                 "progress" => 1,
                 "total" => 2,
                 "message" => "step 1"
               }
             },
             %{"method" => "notifications/progress", "params" => %{"progress" => 2}},
             %{
               "id" => 1,
               "result" => %{"content" => [%{"text" => final}]}
             }
           ] = events

    assert Jason.decode!(final) == %{"done" => 2}
  end

  test "answers JSON when the client does not accept SSE, even with a progress token" do
    message =
      modern("tools/call", %{"name" => "slow", "arguments" => %{"steps" => 1}}, %{
        "progressToken" => "p1"
      })

    conn = post_message(message, modern_headers("tools/call", "slow"))

    assert ["application/json" <> _] = get_resp_header(conn, "content-type")
    assert %{"result" => %{"isError" => false}} = Jason.decode!(conn.resp_body)
  end

  test "closing the stream cancels the call" do
    Application.put_env(:ariadna_mcp, :slow_sleep, 50)
    on_exit(fn -> Application.delete_env(:ariadna_mcp, :slow_sleep) end)

    message =
      modern("tools/call", %{"name" => "slow", "arguments" => %{"steps" => 5}}, %{
        "progressToken" => "p1"
      })

    conn(:post, "/mcp", Jason.encode!(message))
    |> ClosingAdapter.wrap()
    |> put_req_header("content-type", "application/json")
    |> put_req_header("accept", "text/event-stream")
    |> then(fn conn ->
      Enum.reduce(modern_headers("tools/call", "slow"), conn, fn {k, v}, acc ->
        put_req_header(acc, k, v)
      end)
    end)
    |> assign(:current_client, @reader)
    |> AriadnaMCP.Plug.call(@opts)

    assert_received {:slow_step, 1}
    Process.sleep(300)
    refute_received :slow_done
    refute_received {:slow_step, 5}
  end
end
