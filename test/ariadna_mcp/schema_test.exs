defmodule AriadnaMCP.SchemaTest do
  use ExUnit.Case, async: true

  import AriadnaMCP.Schema

  test "object marks required fields and advertises descriptions" do
    schema =
      object(
        %{
          "id" => string("Id"),
          "limit" => integer("Limit"),
          "score" => number("Score"),
          "active" => boolean("Active"),
          "meta" => map("Meta"),
          "tags" => list(:string, "Tags"),
          "kind" => enum(["a", "b"], "Kind")
        },
        required: ["id", "tags"]
      )

    json = to_json_schema(schema)
    assert Enum.sort(json["required"]) == ["id", "tags"]
    assert json["properties"]["id"] == %{"type" => "string", "description" => "Id"}

    assert json["properties"]["tags"] == %{
             "type" => "array",
             "items" => %{"type" => "string"},
             "description" => "Tags"
           }

    assert json["properties"]["kind"]["enum"] == ["a", "b"]
  end

  test "validate keeps declared keys and explains failures" do
    schema = object(%{"id" => string("Id"), "limit" => integer("Limit")}, required: ["id"])

    assert {:ok, %{"id" => "x"}} = validate(schema, %{"id" => "x", "other" => 1})
    assert {:error, "id: " <> _} = validate(schema, %{})
    assert {:error, "limit: " <> _} = validate(schema, %{"id" => "x", "limit" => "many"})
    assert {:error, "arguments must be an object"} = validate(schema, "x")
  end

  test "project drops undeclared fields at every depth and allows nulls" do
    schema =
      nullable(%{
        "items" => {:list, %{"title" => :string, "tags" => {:list, %{"name" => :string}}}}
      })

    result = %{
      items: [%{title: "A", secret: 1, tags: [%{name: "t", id: 9}]}, %{title: nil}],
      total: 2,
      at: ~U[2026-10-05 10:00:00Z]
    }

    assert {:ok,
            %{"items" => [%{"title" => "A", "tags" => [%{"name" => "t"}]}, %{"title" => nil}]}} =
             project(schema, result)

    assert {:error, "items" <> _} = project(nullable(%{"items" => :integer}), %{items: "x"})
  end
end
