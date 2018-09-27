defmodule Helios.Pipeline.Plug do
  alias Helios.Context

  @type opts :: any

  @callback init(opts) :: opts

  @callback call(ctx :: Context.t(), opts :: __MODULE__.opts()) :: Context.t()
end
