defmodule AriadnaMCP.Prompt do
  @moduledoc """
  A prompt template. `:arguments` is a list of `{name, description, required?}`;
  rendering goes through the server's `c:AriadnaMCP.Server.get_prompt/3`.
  """

  @enforce_keys [:name, :description]
  defstruct [:name, :description, :scope, arguments: []]

  @type argument :: {String.t(), String.t() | nil, boolean()}
  @type t :: %__MODULE__{
          name: String.t(),
          description: String.t(),
          scope: term(),
          arguments: [argument()]
        }

  @doc false
  def definition(%__MODULE__{} = prompt) do
    %{
      "name" => prompt.name,
      "description" => prompt.description,
      "arguments" =>
        Enum.map(prompt.arguments, fn {name, description, required} ->
          %{"name" => name, "description" => description, "required" => required}
        end)
    }
  end
end
