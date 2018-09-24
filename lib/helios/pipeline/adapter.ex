defmodule Helios.Pipeline.Adapter do
  alias Helios.Pipeline.Context

  @type payload :: term

  @callback send_resp(payload :: payload, status :: Context.status(), response :: Context.resposne()) ::
              {:ok, sent_body :: binary | nil, payload}
end
