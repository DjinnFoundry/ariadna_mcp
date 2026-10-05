defmodule AriadnaMCP.TestActions do
  @moduledoc false

  defmodule Search do
    @moduledoc false
    use Jido.Action,
      name: "search_library",
      description: "Search the library by text",
      schema:
        Zoi.object(%{
          query: Zoi.string(description: "Text to search"),
          limit: Zoi.integer(description: "Maximum results") |> Zoi.optional()
        }),
      output_schema:
        Zoi.object(%{
          items:
            Zoi.array(
              Zoi.object(%{
                title: Zoi.string(),
                note: Zoi.string() |> Zoi.nullable() |> Zoi.optional()
              })
            )
        })

    @impl true
    def run(%{query: query} = params, context) do
      {:ok,
       %{
         items: [%{title: "#{query} x#{params[:limit] || 1}", note: nil, secret: "hidden"}],
         client: context[:client_name],
         internal: true
       }}
    end
  end

  defmodule Quarter do
    @moduledoc false
    use Jido.Action,
      name: "inspect_quarter",
      description: "Inspect a fiscal quarter",
      schema: [year: [type: :integer, required: true], quarter: [type: :integer, required: true]],
      output_schema: [status: [type: :string]]

    @impl true
    def run(%{year: year, quarter: quarter}, _context),
      do: {:ok, %{status: "#{year}-Q#{quarter} open", internal: %{debug: true}}}
  end

  defmodule Raising do
    @moduledoc false
    use Jido.Action, name: "raising", description: "Raises with internal details"

    @impl true
    def run(_params, _context), do: raise("SELECT secret FROM users failed")
  end

  defmodule Failing do
    @moduledoc false
    use Jido.Action, name: "failing", description: "Always fails"

    @impl true
    def run(_params, _context), do: {:error, "the ledger is locked"}
  end
end

defmodule AriadnaMCP.JidoServer do
  @moduledoc false
  use AriadnaMCP.Server

  alias AriadnaMCP.{Context, JidoAction, TestActions}

  @impl true
  def info, do: %{name: "Jido test", version: "0.0.1"}

  @impl true
  def tools do
    [
      JidoAction.tool(TestActions.Search, scope: "read", context: &__MODULE__.action_context/1),
      JidoAction.tool(TestActions.Quarter, title: "Quarter"),
      JidoAction.tool(TestActions.Failing, write: true),
      JidoAction.tool(TestActions.Raising)
    ]
  end

  def action_context(%Context{client_name: name}), do: %{client_name: name}

  @impl true
  def report_exception(exception, _stacktrace, metadata) do
    if pid = Application.get_env(:ariadna_mcp, :jido_test_pid),
      do: send(pid, {:reported, Exception.message(exception), metadata})

    :ok
  end

  @impl true
  def enabled_write_tools, do: :all

  @impl true
  def authorize(%Context{client: %{scopes: scopes}}, scope),
    do: if(scope in scopes, do: :ok, else: {:error, "client lacks scope #{scope}"})

  def authorize(_context, scope), do: {:error, "client lacks scope #{scope}"}
end
