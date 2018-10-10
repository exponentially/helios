defmodule Helios.Pipeline.Plug do
  @moduledoc """
  Behaviour, when implmented, such module can be used in message context pipeline
  """
  alias Helios.Context

  @type opts :: any

  @callback init(opts) :: opts

  @callback call(ctx :: Context.t(), opts :: __MODULE__.opts()) :: Context.t()
end
