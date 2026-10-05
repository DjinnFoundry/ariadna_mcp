defmodule AriadnaMCP.ResourceTemplate do
  @moduledoc """
  A family of read-only resources addressed by URI, such as
  `library://item/{public_id}`. Reads go through the server's
  `c:AriadnaMCP.Server.read_resource/2`, which also decides the scope a URI needs.
  """

  @enforce_keys [:uri_template, :name]
  defstruct [:uri_template, :name, :description, mime_type: "application/json"]

  @type t :: %__MODULE__{
          uri_template: String.t(),
          name: String.t(),
          description: String.t() | nil,
          mime_type: String.t()
        }

  @doc false
  def definition(%__MODULE__{} = template) do
    %{
      "uriTemplate" => template.uri_template,
      "name" => template.name,
      "description" => template.description,
      "mimeType" => template.mime_type
    }
  end
end
