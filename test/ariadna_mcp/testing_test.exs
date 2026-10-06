defmodule AriadnaMCP.TestingTest do
  use ExUnit.Case, async: true

  alias AriadnaMCP.{Testing, TestServer}

  test "snapshot is deterministic pretty JSON of the served tools" do
    snapshot = Testing.snapshot(TestServer)

    assert snapshot == Testing.snapshot(TestServer)
    assert [%{"name" => "echo"} | _] = Jason.decode!(snapshot)
    refute snapshot =~ "write_note"
    assert snapshot =~ ~s("description": "Echoes a note")
  end

  test "snapshot sorts required lists, which are sets" do
    assert %{"inputSchema" => %{"required" => ["text"]}} =
             TestServer
             |> Testing.snapshot()
             |> Jason.decode!()
             |> Enum.find(&(&1["name"] == "echo"))

    defmodule Unordered do
      @moduledoc false
      use AriadnaMCP.Server
      @impl true
      def info, do: %{name: "U", version: "0"}
      @impl true
      def authorize(_context, _scope), do: :ok

      @impl true
      def tools do
        input = %{"z" => {:required, :string}, "a" => {:required, :string}}

        [
          %AriadnaMCP.Tool{
            name: "t",
            description: "d",
            input: input,
            handler: fn _, _ -> {:ok, %{}} end
          }
        ]
      end
    end

    assert [%{"inputSchema" => %{"required" => ["a", "z"]}}] =
             Unordered |> Testing.snapshot() |> Jason.decode!()
  end

  test "undeclared_paths finds fields outside a JSON Schema" do
    schema = %{
      "type" => "object",
      "properties" => %{
        "items" => %{
          "type" => "array",
          "items" => %{"type" => "object", "properties" => %{"title" => %{"type" => "string"}}}
        },
        "plan" => %{
          "oneOf" => [
            %{"type" => "object", "properties" => %{"name" => %{"type" => "string"}}},
            %{"type" => "null"}
          ]
        }
      }
    }

    assert Testing.undeclared_paths(%{"items" => [%{"title" => "a"}], "plan" => nil}, schema) ==
             []

    assert Testing.undeclared_paths(
             %{
               "items" => [%{"title" => "a", "secret" => 1}],
               "plan" => %{"owner" => "x"},
               "extra" => 1
             },
             schema
           )
           |> Enum.sort() == ["extra", "items.secret", "plan.owner"]
  end

  test "undeclared_paths follows Zoi's anyOf for nullable fields" do
    schema = %{
      "properties" => %{
        "plan" => %{
          "anyOf" => [
            %{"type" => "null"},
            %{"type" => "object", "properties" => %{"name" => %{}}}
          ]
        }
      }
    }

    assert Testing.undeclared_paths(%{"plan" => nil}, schema) == []

    assert Testing.undeclared_paths(%{"plan" => %{"name" => "x", "owner" => "y"}}, schema) == [
             "plan.owner"
           ]
  end

  test "result! raises on errors and request builds legacy messages" do
    assert_raise RuntimeError, ~r/expected a result/, fn ->
      Testing.result!(TestServer, "nope")
    end

    assert %{"params" => %{}} = Testing.request("tools/list", %{}, version: "2025-06-18")
  end
end

defmodule AriadnaMCPTest do
  use ExUnit.Case, async: true

  alias AriadnaMCP.{Context, TestServer}

  test "handle/3 answers one message" do
    message = AriadnaMCP.Testing.request("tools/list")

    assert {200, %{"result" => %{"tools" => [_ | _]}}} =
             AriadnaMCP.handle(TestServer, message, %Context{})
  end

  test "progress is a no-op without a progress function and sends params with one" do
    assert :ok = Context.progress(%Context{}, 1)

    context = %Context{progress_token: "t", progress_fun: &send(self(), {:progress, &1})}
    assert :ok = Context.progress(context, 2, total: 4, message: "half")

    assert_received {:progress,
                     %{"progressToken" => "t", "progress" => 2, "total" => 4, "message" => "half"}}
  end
end
