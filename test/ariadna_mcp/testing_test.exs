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

  test "result! raises on errors and request builds legacy messages" do
    assert_raise RuntimeError, ~r/expected a result/, fn ->
      Testing.result!(TestServer, "nope")
    end

    assert %{"params" => %{}} = Testing.request("tools/list", %{}, version: "2025-06-18")
  end
end
