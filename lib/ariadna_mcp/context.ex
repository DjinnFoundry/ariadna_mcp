defmodule AriadnaMCP.Context do
  @moduledoc """
  What a handler knows about the request it serves.

    * `:client` is whatever the host authenticated (for example an API key
      record); `:client_name` is how it appears in telemetry and audit.
    * `:protocol_version` and `:era` (`:modern` or `:legacy`) describe how the
      client speaks.
    * `:assigns` carries host data from the transport.
    * `progress/3` reports progress on a long operation; it is a no-op when the
      client did not ask for progress or cannot receive it.
  """

  defstruct [
    :client,
    :client_name,
    :protocol_version,
    :progress_token,
    era: :legacy,
    assigns: %{},
    progress_fun: nil
  ]

  @type t :: %__MODULE__{
          client: term(),
          client_name: String.t() | nil,
          protocol_version: String.t() | nil,
          progress_token: String.t() | integer() | nil,
          era: :modern | :legacy,
          assigns: map(),
          progress_fun: (map() -> :ok) | nil
        }

  @doc """
  Reports progress (`progress` so far, optional `total` and `message`). Sent as
  `notifications/progress` on the request's SSE stream.
  """
  @spec progress(t(), number(), keyword()) :: :ok
  def progress(context, progress, opts \\ [])

  def progress(%__MODULE__{progress_fun: nil}, _progress, _opts), do: :ok

  def progress(%__MODULE__{progress_fun: fun, progress_token: token}, progress, opts) do
    params =
      %{"progressToken" => token, "progress" => progress}
      |> put_present("total", opts[:total])
      |> put_present("message", opts[:message])

    fun.(params)
  end

  defp put_present(map, _key, nil), do: map
  defp put_present(map, key, value), do: Map.put(map, key, value)
end
