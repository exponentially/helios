defmodule Helios.Pipeline.Adapter do
  @moduledoc """
  Each message that comes from outer world needs to be adopted to message context.
  By implementing `send_resp/3` adpater should return response body that is sent to
  caller.
  """
  alias Helios.Context

  @type payload :: term
  @type status :: Context.status()
  @type response :: Context.response()

  @type sent_body :: binary | nil

  @callback send_resp(payload, status, response) :: {:ok, sent_body, payload}
end
