defmodule AriadnaMCP.Server do
  @moduledoc """
  The behaviour a product implements to expose its MCP server.

      defmodule MyApp.MCP do
        use AriadnaMCP.Server

        @impl true
        def info, do: %{name: "MyApp", version: "1.0.0", instructions: "..."}

        @impl true
        def tools, do: MyApp.MCP.ToolRegistry.all()

        @impl true
        def authorize(%AriadnaMCP.Context{client: client}, scope),
          do: if(scope in client.scopes, do: :ok, else: {:error, "missing scope \#{scope}"})
      end

  `use AriadnaMCP.Server` provides defaults for every optional callback. The
  defaults are the safe ones: no resources, no prompts, no write tools served,
  no audit.
  """

  alias AriadnaMCP.{Context, Prompt, ResourceTemplate, Tool}

  @type info :: %{
          required(:name) => String.t(),
          required(:version) => String.t(),
          optional(:instructions) => String.t() | nil
        }

  @type prompt_result :: %{description: String.t() | nil, messages: [String.t()]}

  @doc "Name, version and optional instructions for the model."
  @callback info() :: info()

  @doc """
  Every tool in the catalog. Write tools are filtered by
  `c:enabled_write_tools/0`, and `tools/list` shows each client only the tools
  `c:authorize/2` allows it.
  """
  @callback tools() :: [Tool.t()]

  @doc """
  Allows or denies a scope for the request's client. `nil` scopes are never
  checked. A tool call denied with a map gets it as `structuredContent`.
  """
  @callback authorize(Context.t(), scope :: term()) :: :ok | {:error, String.t() | map()}

  @doc "Write tools served: `:all` or a list of tool names. Default: none."
  @callback enabled_write_tools() :: :all | [String.t()]

  @doc "Resource templates offered. Default: none."
  @callback resource_templates() :: [ResourceTemplate.t()]

  @doc "The scope a resource URI needs, or `nil` for an unknown URI."
  @callback resource_scope(uri :: String.t()) :: term()

  @doc "Reads a resource; the payload is returned as JSON text."
  @callback read_resource(uri :: String.t(), Context.t()) :: {:ok, term()} | {:error, String.t()}

  @doc "Prompts offered. Default: none."
  @callback prompts() :: [Prompt.t()]

  @doc "Renders a prompt with its arguments."
  @callback get_prompt(name :: String.t(), arguments :: map(), Context.t()) ::
              {:ok, prompt_result()} | {:error, String.t()}

  @doc """
  Records an access: `:tool_called`, `:resource_read`, `:prompt_get` or
  `:scope_denied`, with the subject (tool name, URI or prompt name) and
  metadata (`:params` is the shape of the arguments, never their values).
  """
  @callback audit(event :: atom(), subject :: String.t(), Context.t(), metadata :: map()) ::
              term()

  @doc "Reports an unexpected exception raised by a handler."
  @callback report_exception(Exception.t(), Exception.stacktrace(), metadata :: map()) :: term()

  @doc "Prefix for telemetry events. Default: `[:ariadna_mcp]`."
  @callback telemetry_prefix() :: [atom()]

  defmacro __using__(_opts) do
    quote do
      @behaviour AriadnaMCP.Server

      @impl AriadnaMCP.Server
      def enabled_write_tools, do: []

      @impl AriadnaMCP.Server
      def resource_templates, do: []

      @impl AriadnaMCP.Server
      def resource_scope(_uri), do: nil

      @impl AriadnaMCP.Server
      def read_resource(uri, _context), do: {:error, "Unknown resource URI: #{uri}"}

      @impl AriadnaMCP.Server
      def prompts, do: []

      @impl AriadnaMCP.Server
      def get_prompt(name, _arguments, _context), do: {:error, "Unknown prompt #{name}"}

      @impl AriadnaMCP.Server
      def audit(_event, _subject, _context, _metadata), do: :ok

      @impl AriadnaMCP.Server
      def report_exception(exception, stacktrace, metadata) do
        require Logger

        Logger.error(
          "MCP handler failed: " <> Exception.format(:error, exception, stacktrace),
          metadata |> Map.to_list()
        )
      end

      @impl AriadnaMCP.Server
      def telemetry_prefix, do: [:ariadna_mcp]

      defoverridable enabled_write_tools: 0,
                     resource_templates: 0,
                     resource_scope: 1,
                     read_resource: 2,
                     prompts: 0,
                     get_prompt: 3,
                     audit: 4,
                     report_exception: 3,
                     telemetry_prefix: 0
    end
  end

  @doc "The tools a server serves: read tools always, write tools when enabled."
  @spec served_tools(module()) :: [Tool.t()]
  def served_tools(server) do
    case server.enabled_write_tools() do
      :all -> server.tools()
      names -> Enum.filter(server.tools(), &(not &1.write or &1.name in names))
    end
  end

  @doc "A served tool by name."
  @spec served_tool(module(), String.t()) :: Tool.t() | nil
  def served_tool(server, name), do: Enum.find(served_tools(server), &(&1.name == name))
end
