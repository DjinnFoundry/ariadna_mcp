defmodule AriadnaMCP.TestServer do
  @moduledoc false
  use AriadnaMCP.Server

  import AriadnaMCP.Schema

  alias AriadnaMCP.{Context, Prompt, ResourceTemplate, Tool}

  @impl true
  def info, do: %{name: "Test", version: "1.2.3", instructions: "Use the test tools."}

  @impl true
  def tools do
    [
      %Tool{
        name: "echo",
        description: "Echoes a note",
        scope: "read",
        input:
          object(%{"text" => string("Text to echo"), "times" => integer("Repeats")},
            required: ["text"]
          ),
        output: nullable(%{"note" => %{"text" => :string, "times" => :integer}}),
        handler: {__MODULE__, :echo}
      },
      %Tool{
        name: "plain",
        description: "Returns text without an output schema",
        handler: fn _arguments, _context -> {:ok, "plain text"} end
      },
      %Tool{
        name: "write_note",
        description: "Writes a note",
        scope: "write",
        write: true,
        input: object(%{"text" => string("Text")}),
        handler: fn arguments, _context -> {:ok, arguments} end
      },
      %Tool{
        name: "admin_only",
        description: "Needs the admin scope",
        scope: "admin",
        handler: fn _arguments, _context -> {:ok, %{}} end
      },
      %Tool{
        name: "fails",
        description: "Returns a domain error",
        handler: fn _arguments, _context -> {:error, "not today"} end
      },
      %Tool{
        name: "boom",
        description: "Raises",
        handler: fn _arguments, _context -> raise "kaboom" end
      },
      %Tool{
        name: "bad_output",
        description: "Returns a result that breaks its output schema",
        output: nullable(%{"count" => :integer}),
        handler: fn _arguments, _context -> {:ok, %{count: "many"}} end
      },
      %Tool{
        name: "slow",
        description: "Reports progress",
        input: object(%{"steps" => integer("Steps")}),
        handler: {__MODULE__, :slow}
      }
    ]
  end

  def echo(%{"text" => text} = arguments, _context) do
    {:ok, %{note: %{text: text, times: arguments["times"] || 1, secret: "hidden"}, extra: true}}
  end

  def slow(arguments, context) do
    steps = arguments["steps"] || 2

    for step <- 1..steps do
      notify({:slow_step, step})
      Context.progress(context, step, total: steps, message: "step #{step}")
      Process.sleep(Application.get_env(:ariadna_mcp, :slow_sleep, 0))
    end

    notify(:slow_done)
    {:ok, %{done: steps}}
  end

  @impl true
  def authorize(%Context{client: %{scopes: scopes}}, scope) do
    if scope in scopes, do: :ok, else: {:error, "client lacks scope #{scope}"}
  end

  def authorize(_context, scope), do: {:error, "client lacks scope #{scope}"}

  @impl true
  def enabled_write_tools, do: Application.get_env(:ariadna_mcp, :enabled_write_tools, [])

  @impl true
  def resource_templates,
    do: [%ResourceTemplate{uri_template: "note://{id}", name: "note", description: "A note"}]

  @impl true
  def resource_scope("note://" <> _id), do: "read"
  def resource_scope(_uri), do: nil

  @impl true
  def read_resource("note://missing", _context), do: {:error, "note not found"}
  def read_resource("note://" <> id, _context), do: {:ok, %{id: id, text: "hello"}}

  @impl true
  def prompts do
    [
      %Prompt{
        name: "summarize",
        description: "Summarize a note",
        scope: "read",
        arguments: [{"id", "Note id", true}]
      },
      %Prompt{name: "broken", description: "Fails to render"}
    ]
  end

  @impl true
  def get_prompt("summarize", %{"id" => id}, _context),
    do: {:ok, %{description: nil, messages: ["Summarize note #{id}"]}}

  def get_prompt(_name, _arguments, _context), do: {:error, "cannot render"}

  @impl true
  def audit(event, subject, context, metadata),
    do: notify({:audit, event, subject, context.client_name, metadata})

  @impl true
  def report_exception(exception, _stacktrace, metadata),
    do: notify({:exception, Exception.message(exception), metadata})

  @impl true
  def telemetry_prefix, do: [:test_mcp]

  defp notify(message) do
    if pid = Application.get_env(:ariadna_mcp, :test_pid), do: send(pid, message)
    :ok
  end
end
