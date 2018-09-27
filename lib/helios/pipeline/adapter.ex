defmodule Helios.Pipeline.Adapter do
  alias Helios.Context

  @type payload :: term
  @type status :: Context.status()
  @type response :: Context.response()

  @type sent_body :: binary | nil

  @callback send_resp(payload, status, response) :: {:ok, sent_body, payload}
end
