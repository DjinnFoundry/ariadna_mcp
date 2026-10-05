defmodule AriadnaMCP.Schema do
  @moduledoc """
  Tool schemas in [Peri](https://hexdocs.pm/peri) format.

  One Peri schema serves three purposes: it is advertised to clients as JSON
  Schema, it validates arguments (dropping every undeclared key, so a tool must
  declare every argument it reads), and, for output schemas, it is the
  allowlist a result is projected onto before it leaves the server.

      import AriadnaMCP.Schema

      object(
        %{
          "public_id" => string("Training plan public id"),
          "limit" => integer("Maximum number of results")
        },
        required: ["public_id"]
      )
  """

  @type t :: map()

  @doc "Builds an input schema from properties, marking the `:required` keys."
  @spec object(map(), keyword()) :: t()
  def object(properties, opts \\ []) when is_map(properties) do
    required = Keyword.get(opts, :required, [])

    Map.new(properties, fn {key, type} ->
      {key, if(key in required, do: required(type), else: type)}
    end)
  end

  @doc "A string field with a description."
  def string(description), do: described(:string, description)
  @doc "An integer field with a description."
  def integer(description), do: described(:integer, description)
  @doc "A number field (integer or float) with a description."
  def number(description), do: described({:either, {:float, :integer}}, description)
  @doc "A boolean field with a description."
  def boolean(description), do: described(:boolean, description)
  @doc "A free-form object field with a description."
  def map(description), do: described(:map, description)
  @doc "A list of `item` with a description."
  def list(item, description), do: described({:list, item}, description)

  @doc "An enumerated string field with a description."
  def enum(values, description) when is_list(values),
    do: described({:enum, values}, description)

  @doc "Marks a field as required."
  def required({:meta, type, opts}), do: {:meta, {:required, type}, opts}
  def required(type), do: {:required, type}

  @doc """
  Makes every field of an output schema nullable, recursively, so results with
  `nil` values validate and the advertised JSON Schema allows `null`.
  """
  @spec nullable(t()) :: t()
  def nullable(fields) when is_map(fields),
    do: Map.new(fields, fn {key, type} -> {key, {:either, {nullable_type(type), nil}}} end)

  defp nullable_type(fields) when is_map(fields), do: nullable(fields)
  defp nullable_type({:list, item}), do: {:list, nullable_type(item)}
  defp nullable_type(type), do: type

  @doc "The JSON Schema advertised for a Peri schema."
  @spec to_json_schema(t()) :: map()
  def to_json_schema(schema), do: Peri.to_json_schema(schema)

  @doc "Validates arguments, returning only the declared keys."
  @spec validate(t(), map()) :: {:ok, map()} | {:error, String.t()}
  def validate(schema, arguments) when is_map(arguments) do
    case Peri.validate(schema, arguments) do
      {:ok, valid} -> {:ok, valid}
      {:error, errors} -> {:error, format_errors(errors)}
    end
  end

  def validate(_schema, _arguments), do: {:error, "arguments must be an object"}

  @doc """
  Projects a result onto an output schema: the JSON form of the result keeps
  only the fields the schema declares, at every depth.
  """
  @spec project(t(), term()) :: {:ok, map()} | {:error, String.t()}
  def project(schema, result) do
    json = result |> Jason.encode!() |> Jason.decode!()

    case Peri.validate(schema, json) do
      {:ok, projected} -> {:ok, projected}
      {:error, errors} -> {:error, format_errors(errors)}
    end
  end

  defp described(type, description), do: {:meta, type, description: description}

  defp format_errors(errors) when is_list(errors),
    do: Enum.map_join(errors, "; ", &format_error/1)

  defp format_errors(error), do: format_error(error)

  defp format_error(%Peri.Error{path: path, message: message}),
    do: "#{Enum.join(path, ".")}: #{message}"

  defp format_error(other), do: inspect(other)
end
