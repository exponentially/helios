defmodule Helios.Pipeline.Plug do
  @moduledoc """
  Behaviour, when implmented, such module can be used in message context pipeline
  """
  alias Helios.Context

  @typedoc """
  Module that implements #{__MODULE__} behaviour
  """
  @type t :: module() | atom()

  @type opts :: Keyword.t()

  @callback init(opts) :: opts

  @callback call(ctx :: Context.t(), opts :: __MODULE__.opts()) :: Context.t()
end
