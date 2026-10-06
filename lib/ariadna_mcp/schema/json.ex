defmodule AriadnaMCP.Schema.JSON do
  @moduledoc """
  A tool schema written as JSON Schema and published as it is:
  `input: {AriadnaMCP.Schema.JSON, %{"type" => "object", ...}}`.

  It validates nothing: arguments reach the handler as the client sent them,
  so the handler checks them and answers its own errors. Use it when the
  product already owns its schemas and their validation.
  """

  @behaviour AriadnaMCP.Schema.Adapter

  @impl true
  def to_json_schema(schema) when is_map(schema), do: schema

  @impl true
  def validate(_schema, arguments), do: {:ok, arguments}

  @impl true
  def project(_schema, result), do: {:ok, result}
end
