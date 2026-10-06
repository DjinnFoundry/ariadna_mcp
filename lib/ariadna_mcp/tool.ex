defmodule AriadnaMCP.Tool do
  @moduledoc """
  A tool the server offers.

    * `:name` and `:description` are what the model reads to decide when to call it.
    * `:handler` is `{module, function}` or a 2-arity function, called with the
      validated arguments and the `AriadnaMCP.Context`; it returns
      `{:ok, result}` or `{:error, reason}`. An object result or reason
      reaches the client as `structuredContent` and as its JSON text; a
      string as text only. A tool without `:output` may answer
      `{:ok, {:content, blocks}}` to send its own MCP content blocks as they
      are. An exception or an exit inside the handler is reported to the
      server and answered as a tool error.
    * `:scope` is passed to the server's `c:AriadnaMCP.Server.authorize/2`; `nil`
      means no authorization check.
    * `:write` marks tools that change data: they are served only when the
      server lists them in `c:AriadnaMCP.Server.enabled_write_tools/0`.
    * `:input` and `:output` are Peri schemas (`AriadnaMCP.Schema`). With an
      `:output` schema the result is projected onto it and returned as
      `structuredContent`; without one it is returned as JSON text.
  """

  @enforce_keys [:name, :description, :handler]
  defstruct [
    :name,
    :title,
    :description,
    :handler,
    :scope,
    :output,
    :annotations,
    write: false,
    input: %{}
  ]

  @type handler :: {module(), atom()} | (map(), AriadnaMCP.Context.t() -> result())
  @type result :: {:ok, term() | {:content, [map()]}} | {:error, String.t() | map()}
  @type t :: %__MODULE__{
          name: String.t(),
          title: String.t() | nil,
          description: String.t(),
          handler: handler(),
          scope: term(),
          output: AriadnaMCP.Schema.t() | nil,
          annotations: map() | nil,
          write: boolean(),
          input: AriadnaMCP.Schema.t()
        }

  @doc false
  @spec run(t(), map(), AriadnaMCP.Context.t()) :: result()
  def run(%__MODULE__{handler: {module, function}}, arguments, context),
    do: apply(module, function, [arguments, context])

  def run(%__MODULE__{handler: handler}, arguments, context) when is_function(handler, 2),
    do: handler.(arguments, context)

  @doc false
  @spec definition(t()) :: map()
  def definition(%__MODULE__{} = tool) do
    %{
      "name" => tool.name,
      "description" => tool.description,
      "inputSchema" => AriadnaMCP.Schema.to_json_schema(tool.input)
    }
    |> put_present("title", tool.title)
    |> put_present("annotations", tool.annotations)
    |> put_present("outputSchema", tool.output && AriadnaMCP.Schema.to_json_schema(tool.output))
  end

  defp put_present(map, _key, nil), do: map
  defp put_present(map, key, value), do: Map.put(map, key, value)
end
