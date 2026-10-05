if Code.ensure_loaded?(Jido.Action.Schema) do
  defmodule AriadnaMCP.JidoAction do
    @moduledoc """
    Serves `Jido.Action` modules as MCP tools, so one action is the single
    definition behind an in-process agent (`jido_ai`), the MCP server and the
    UI.

        AriadnaMCP.JidoAction.tool(MyApp.Actions.SearchLibrary,
          scope: "read:library",
          context: &MyApp.MCP.action_context/1
        )

    What it adds on top of Jido:

      * MCP arguments arrive with string keys; they are converted to the
        schema's atom keys (`Jido.Action.Tool.convert_params_using_schema/2`,
        no new atoms) and validated before the action runs, so invalid
        arguments are a protocol error.
      * Results are projected onto the action's `output_schema` here, not left
        to Jido, which lets undeclared top-level keys through. A Zoi output
        schema strips undeclared fields at every depth; a NimbleOptions one
        only at the top level, so declare outputs with Zoi.

    Options:

      * `:scope`, `:write`, `:title`, `:annotations` - as in `AriadnaMCP.Tool`.
      * `:context` - `AriadnaMCP.Context -> map` for the action's context;
        defaults to `%{mcp: context}`.
      * `:exec` - options for `Jido.Exec.run/4`, such as `timeout:`. Defaults:
        `max_retries: 0` (retrying is the MCP client's decision, and a retried
        write or AI call costs twice) and `log_level: :critical` (a domain error
        is an answer, not a server error; exceptions are reported by the server).
    """

    @behaviour AriadnaMCP.Schema.Adapter

    @default_exec [max_retries: 0, log_level: :critical]

    alias AriadnaMCP.Tool
    alias Jido.Action.Schema, as: JidoSchema

    @doc "An `AriadnaMCP.Tool` for a `Jido.Action` module."
    @spec tool(module(), keyword()) :: Tool.t()
    def tool(action, opts \\ []) when is_atom(action) do
      context_fun = Keyword.get(opts, :context, &__MODULE__.default_context/1)
      exec_opts = Keyword.merge(@default_exec, Keyword.get(opts, :exec, []))

      %Tool{
        name: action.name(),
        description: action.description(),
        title: opts[:title],
        annotations: opts[:annotations],
        scope: opts[:scope],
        write: Keyword.get(opts, :write, false),
        input: {__MODULE__, action.schema()},
        output: output(action.output_schema()),
        handler: fn arguments, context ->
          run(action, arguments, context_fun.(context), exec_opts)
        end
      }
    end

    @doc false
    def default_context(context), do: %{mcp: context}

    @doc """
    Runs an action with already validated arguments. An exception raised by the
    action is raised again, so the server reports it and the client only sees
    `internal_error`: Jido would otherwise return its message.
    """
    @spec run(module(), map(), map(), keyword()) :: Tool.result()
    def run(action, arguments, context, exec_opts \\ []) do
      case Jido.Exec.run(action, arguments, context, exec_opts) do
        {:ok, result} -> {:ok, result}
        {:ok, result, _directives} -> {:ok, result}
        {:error, error} -> error(error)
        {:error, error, _directives} -> error(error)
      end
    end

    defp error(%{details: %{original_exception: exception} = details})
         when is_exception(exception),
         do: reraise(exception, Map.get(details, :stacktrace, []))

    defp error(%Jido.Action.Error.InternalError{}), do: {:error, "internal_error"}
    defp error(error), do: {:error, message(error)}

    @impl AriadnaMCP.Schema.Adapter
    def to_json_schema(schema) do
      schema
      |> JidoSchema.to_json_schema()
      |> json()
      |> Map.delete("$schema")
    end

    @impl AriadnaMCP.Schema.Adapter
    def validate(schema, arguments) do
      params = Jido.Action.Tool.convert_params_using_schema(arguments, schema)

      case JidoSchema.validate(schema, params) do
        {:ok, valid} -> {:ok, Map.new(valid)}
        {:error, error} -> {:error, message(error)}
      end
    end

    @impl AriadnaMCP.Schema.Adapter
    def project(schema, result) do
      result = json(result)

      case JidoSchema.schema_type(schema) do
        :zoi -> project_zoi(schema, result)
        :nimble -> {:ok, Map.take(result, Enum.map(JidoSchema.known_keys(schema), &to_string/1))}
        _other -> {:ok, result}
      end
    end

    defp project_zoi(schema, result) do
      case Zoi.parse(schema, result, coerce: true) do
        {:ok, projected} -> {:ok, json(projected)}
        {:error, errors} -> {:error, message(errors)}
      end
    end

    defp output(schema) when schema in [nil, []], do: nil
    defp output(schema), do: {__MODULE__, schema}

    defp json(term), do: term |> Jason.encode!() |> Jason.decode!()

    defp message(errors) when is_list(errors), do: Enum.map_join(errors, "; ", &message/1)

    defp message(%{path: path, message: message}) when is_list(path) and path != [],
      do: "#{Enum.join(path, ".")}: #{message}"

    defp message(%{message: message}) when is_binary(message), do: message
    defp message(message) when is_binary(message), do: message
    defp message(other), do: inspect(other)
  end
end
