defmodule AriadnaMCP.Protocol do
  @moduledoc """
  The MCP protocol, without sessions, for both eras of the specification.

  * **Modern** (2026-07-28 and later): every request carries its protocol
    version in `params._meta`; there is no `initialize`, and over HTTP the
    `MCP-Protocol-Version`, `Mcp-Method` and `Mcp-Name` headers must match the
    body. Results carry `resultType` and `serverInfo`.
  * **Legacy** (2025-03-26 to 2025-11-25): clients start with `initialize`.
    Requests are still answered one by one, with no session, so any replica can
    serve any request.

  `negotiate/3` decides the era and validates version and headers; `dispatch/3`
  runs the method. `handle/3` does both. Each returns `{status, body}`, with the
  HTTP status the transport should use (`body` is `nil` for 202).
  """

  alias AriadnaMCP.{Context, Prompt, ResourceTemplate, Schema, Server, Tool}

  @modern_versions ["2026-07-28"]
  @legacy_versions ["2025-11-25", "2025-06-18", "2025-03-26"]
  @supported_versions @modern_versions ++ @legacy_versions
  @latest_legacy "2025-11-25"
  @default_legacy "2025-03-26"

  @version_key "io.modelcontextprotocol/protocolVersion"
  @server_info_key "io.modelcontextprotocol/serverInfo"

  @parse_error -32_700
  @invalid_request -32_600
  @method_not_found -32_601
  @invalid_params -32_602
  @header_mismatch -32_020
  @unsupported_version -32_022
  @resource_not_found -32_002

  @named_methods %{"tools/call" => "name", "resources/read" => "uri", "prompts/get" => "name"}

  @typedoc "Transport headers mirrored from the body; `nil` when not over HTTP."
  @type headers :: %{
          protocol_version: String.t() | nil,
          method: String.t() | nil,
          name: String.t() | nil
        }

  @type reply :: {pos_integer(), map() | nil}

  @doc "Protocol versions this library speaks, newest first."
  @spec supported_versions() :: [String.t()]
  def supported_versions, do: @supported_versions

  @doc "Negotiates and dispatches one JSON-RPC message."
  @spec handle(module(), term(), Context.t(), headers() | nil) :: reply()
  def handle(server, message, %Context{} = context, headers \\ nil) do
    case negotiate(message, context, headers) do
      {:ok, context} -> dispatch(server, message, context)
      {:reply, _status, _body} = reply -> unwrap(reply)
    end
  end

  @doc """
  Decides the era and protocol version of a message and validates its headers.
  Returns the context to dispatch with, or the reply to send right away.
  """
  @spec negotiate(term(), Context.t(), headers() | nil) ::
          {:ok, Context.t()} | {:reply, pos_integer(), map() | nil}
  def negotiate(%{"jsonrpc" => "2.0", "method" => method} = message, context, headers)
      when is_binary(method) do
    id = message["id"]
    meta = meta(message)
    body_version = meta[@version_key]
    header_version = headers && headers.protocol_version

    cond do
      is_binary(body_version) ->
        negotiate_modern(message, body_version, meta, context, headers)

      header_version in @modern_versions ->
        error_reply(
          id,
          400,
          @header_mismatch,
          "Header mismatch: #{@version_key} is missing from _meta"
        )

      is_binary(header_version) and header_version not in @legacy_versions ->
        unsupported_version(id, header_version)

      true ->
        {:ok, %{context | era: :legacy, protocol_version: header_version || @default_legacy}}
    end
  end

  def negotiate(message, _context, _headers) when is_map(message),
    do: error_reply(message["id"], 200, @invalid_request, "Invalid Request")

  def negotiate(_message, _context, _headers),
    do: error_reply(nil, 200, @invalid_request, "Invalid Request")

  defp negotiate_modern(message, version, meta, context, headers) do
    id = message["id"]

    cond do
      version not in @modern_versions ->
        unsupported_version(id, version)

      mismatch = headers && header_mismatch(message, version, headers) ->
        error_reply(id, 400, @header_mismatch, "Header mismatch: " <> mismatch)

      true ->
        {:ok,
         %{
           context
           | era: :modern,
             protocol_version: version,
             progress_token: meta["progressToken"]
         }}
    end
  end

  defp header_mismatch(message, version, headers) do
    method = message["method"]
    name_field = @named_methods[method]
    body_name = name_field && get_in(message, ["params", name_field])

    cond do
      headers.protocol_version != version ->
        "MCP-Protocol-Version header #{inspect(headers.protocol_version)} does not match #{version}"

      headers.method != method ->
        "Mcp-Method header #{inspect(headers.method)} does not match #{method}"

      name_field && headers.name != body_name ->
        "Mcp-Name header #{inspect(headers.name)} does not match #{inspect(body_name)}"

      true ->
        nil
    end
  end

  @doc "Runs a negotiated message."
  @spec dispatch(module(), map(), Context.t()) :: reply()
  def dispatch(_server, %{"method" => _} = message, _context) when not is_map_key(message, "id"),
    do: {202, nil}

  def dispatch(server, %{"id" => id, "method" => method} = message, context) do
    params = message["params"] || %{}

    case respond(server, method, params, context) do
      {:result, result} -> {200, result_response(server, id, result, context)}
      {:error, code, text} -> {status_for(code, context), error_response(id, code, text)}
    end
  end

  defp respond(server, "initialize", params, %Context{era: :legacy}) do
    requested = params["protocolVersion"]
    version = if requested in @legacy_versions, do: requested, else: @latest_legacy
    info = server.info()

    {:result,
     %{
       "protocolVersion" => version,
       "capabilities" => capabilities(server),
       "serverInfo" => server_info(info)
     }
     |> put_present("instructions", info[:instructions])}
  end

  defp respond(_server, "ping", _params, %Context{era: :legacy}), do: {:result, %{}}

  defp respond(server, "server/discover", _params, _context) do
    info = server.info()

    {:result,
     %{
       "supportedVersions" => @supported_versions,
       "capabilities" => capabilities(server),
       "ttlMs" => 3_600_000,
       "cacheScope" => "public"
     }
     |> put_present("instructions", info[:instructions])}
  end

  defp respond(server, "tools/list", _params, _context),
    do: {:result, %{"tools" => Enum.map(Server.served_tools(server), &Tool.definition/1)}}

  defp respond(server, "tools/call", %{"name" => name} = params, context) do
    case Server.served_tool(server, name) do
      nil -> {:error, @invalid_params, "Tool not found: #{name}"}
      tool -> call_tool(server, tool, params["arguments"] || %{}, context)
    end
  end

  defp respond(_server, "resources/list", _params, _context), do: {:result, %{"resources" => []}}

  defp respond(server, "resources/templates/list", _params, _context) do
    templates = Enum.map(server.resource_templates(), &ResourceTemplate.definition/1)
    {:result, %{"resourceTemplates" => templates}}
  end

  defp respond(server, "resources/read", %{"uri" => uri}, context) when is_binary(uri),
    do: read_resource(server, uri, context)

  defp respond(server, "prompts/list", _params, _context),
    do: {:result, %{"prompts" => Enum.map(server.prompts(), &Prompt.definition/1)}}

  defp respond(server, "prompts/get", %{"name" => name} = params, context),
    do: get_prompt(server, name, params["arguments"] || %{}, context)

  defp respond(_server, method, _params, _context) when is_map_key(@named_methods, method),
    do: {:error, @invalid_params, "Invalid params"}

  defp respond(_server, _method, _params, _context),
    do: {:error, @method_not_found, "Method not found"}

  defp call_tool(server, tool, arguments, context) do
    metadata = %{tool: tool.name, client_name: context.client_name}
    started_at = emit_start(server, :tool_call, metadata)

    try do
      result = run_tool(server, tool, arguments, context)
      emit_stop(server, :tool_call, started_at, Map.put(metadata, :status, status(result)))
      result
    rescue
      exception ->
        emit_exception(server, :tool_call, started_at, metadata, exception, __STACKTRACE__)

        server.report_exception(exception, __STACKTRACE__, %{context: "mcp_tool", tool: tool.name})

        {:result, tool_error("internal_error")}
    end
  end

  defp run_tool(server, tool, arguments, context) do
    with {:ok, arguments} <- validate_arguments(tool, arguments),
         :ok <- authorize(server, context, tool.scope, tool.name),
         {:ok, result} <- Tool.run(tool, arguments, context),
         {:ok, content} <- tool_content(server, tool, result) do
      server.audit(:tool_called, tool.name, context, %{params: shape(arguments)})
      {:result, content}
    else
      {:invalid_arguments, message} -> {:error, @invalid_params, message}
      {:error, message} -> {:result, tool_error(message)}
    end
  end

  defp validate_arguments(tool, arguments) do
    case Schema.validate(tool.input, arguments) do
      {:ok, valid} -> {:ok, valid}
      {:error, message} -> {:invalid_arguments, message}
    end
  end

  defp tool_content(_server, %Tool{output: nil}, result),
    do: {:ok, %{"content" => [text_block(result)], "isError" => false}}

  defp tool_content(server, %Tool{output: output} = tool, result) do
    case Schema.project(output, result) do
      {:ok, projected} ->
        {:ok,
         %{
           "content" => [%{"type" => "text", "text" => Jason.encode!(projected)}],
           "structuredContent" => projected,
           "isError" => false
         }}

      {:error, reason} ->
        server.report_exception(
          %RuntimeError{message: "MCP tool result does not match its output schema: #{reason}"},
          [],
          %{context: "mcp_tool_output", tool: tool.name}
        )

        {:error, "internal_error"}
    end
  end

  defp read_resource(server, uri, context) do
    metadata = %{uri_scheme: uri_scheme(uri), client_name: context.client_name}
    started_at = emit_start(server, :resource_read, metadata)

    try do
      result =
        with scope when not is_nil(scope) <- server.resource_scope(uri),
             :ok <- authorize(server, context, scope, uri),
             {:ok, payload} <- server.read_resource(uri, context) do
          server.audit(:resource_read, uri, context, %{})

          contents = %{
            "uri" => uri,
            "mimeType" => "application/json",
            "text" => Jason.encode!(payload)
          }

          {:result, %{"contents" => [contents]}}
        else
          nil -> {:error, @resource_not_found, "Unknown resource URI: #{uri}"}
          {:error, message} -> {:error, @resource_not_found, to_string(message)}
        end

      emit_stop(server, :resource_read, started_at, Map.put(metadata, :status, status(result)))
      result
    rescue
      exception ->
        emit_exception(server, :resource_read, started_at, metadata, exception, __STACKTRACE__)
        server.report_exception(exception, __STACKTRACE__, %{context: "mcp_resource", uri: uri})
        {:error, @resource_not_found, "internal_error"}
    end
  end

  defp get_prompt(server, name, arguments, context) do
    with %Prompt{} = prompt <- Enum.find(server.prompts(), &(&1.name == name)),
         :ok <- authorize(server, context, prompt.scope, name),
         {:ok, rendered} <- server.get_prompt(name, arguments, context) do
      server.audit(:prompt_get, name, context, %{})

      {:result,
       %{
         "description" => rendered[:description] || prompt.description,
         "messages" =>
           Enum.map(rendered.messages, fn text ->
             %{"role" => "user", "content" => %{"type" => "text", "text" => text}}
           end)
       }}
    else
      nil -> {:error, @invalid_params, "Unknown prompt #{name}"}
      {:error, message} -> {:error, @invalid_params, message}
    end
  end

  defp authorize(_server, _context, nil, _subject), do: :ok

  defp authorize(server, context, scope, subject) do
    case server.authorize(context, scope) do
      :ok ->
        :ok

      {:error, message} = error ->
        server.audit(:scope_denied, subject, context, %{reason: message})
        error
    end
  end

  defp capabilities(server) do
    %{"tools" => %{"listChanged" => false}}
    |> put_if(server.resource_templates() != [], "resources", %{"listChanged" => false})
    |> put_if(server.prompts() != [], "prompts", %{"listChanged" => false})
  end

  defp result_response(server, id, result, %Context{era: :modern}) do
    result =
      result
      |> Map.put("resultType", "complete")
      |> Map.put("_meta", %{@server_info_key => server_info(server.info())})

    %{"jsonrpc" => "2.0", "id" => id, "result" => result}
  end

  defp result_response(_server, id, result, _context),
    do: %{"jsonrpc" => "2.0", "id" => id, "result" => result}

  defp error_response(id, code, message),
    do: %{"jsonrpc" => "2.0", "id" => id, "error" => %{"code" => code, "message" => message}}

  defp error_reply(id, status, code, message),
    do: {:reply, status, error_response(id, code, message)}

  defp unsupported_version(id, requested) do
    body =
      id
      |> error_response(@unsupported_version, "Unsupported protocol version")
      |> put_in(["error", "data"], %{"supported" => @supported_versions, "requested" => requested})

    {:reply, 400, body}
  end

  defp unwrap({:reply, status, body}), do: {status, body}

  defp status_for(@method_not_found, %Context{era: :modern}), do: 404
  defp status_for(_code, _context), do: 200

  @doc false
  def parse_error, do: {400, error_response(nil, @parse_error, "Parse error")}

  defp text_block(result) when is_binary(result), do: %{"type" => "text", "text" => result}
  defp text_block(result), do: %{"type" => "text", "text" => Jason.encode!(result)}

  defp tool_error(message),
    do: %{"content" => [%{"type" => "text", "text" => to_string(message)}], "isError" => true}

  defp status({:result, %{"isError" => true}}), do: :error
  defp status({:result, _result}), do: :ok
  defp status(_result), do: :error

  # The audit trail keeps the shape of the arguments, never their values.
  defp shape(arguments),
    do: %{"keys" => arguments |> Map.keys() |> Enum.map(&to_string/1) |> Enum.sort()}

  defp server_info(info), do: %{"name" => info.name, "version" => info.version}

  defp meta(%{"params" => %{"_meta" => meta}}) when is_map(meta), do: meta
  defp meta(_message), do: %{}

  defp uri_scheme(uri), do: uri |> String.split("://", parts: 2) |> List.first()

  defp put_present(map, _key, nil), do: map
  defp put_present(map, key, value), do: Map.put(map, key, value)

  defp put_if(map, true, key, value), do: Map.put(map, key, value)
  defp put_if(map, false, _key, _value), do: map

  defp emit_start(server, operation, metadata) do
    :telemetry.execute(
      server.telemetry_prefix() ++ [operation, :start],
      %{system_time: System.system_time()},
      metadata
    )

    System.monotonic_time()
  end

  defp emit_stop(server, operation, started_at, metadata) do
    :telemetry.execute(
      server.telemetry_prefix() ++ [operation, :stop],
      %{duration: System.monotonic_time() - started_at},
      metadata
    )
  end

  defp emit_exception(server, operation, started_at, metadata, exception, stacktrace) do
    :telemetry.execute(
      server.telemetry_prefix() ++ [operation, :exception],
      %{duration: System.monotonic_time() - started_at},
      Map.merge(metadata, %{kind: :error, reason: exception, stacktrace: stacktrace})
    )
  end
end
