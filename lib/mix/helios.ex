defmodule Mix.Helios do
  def base() do
    app_base(otp_app())
  end


  defp app_base(app) do
    case Application.get_env(app, :namespace, app) do
      ^app -> app |> to_string |> Helios.Naming.camelize()
      mod  -> mod |> inspect()
    end
  end

  @doc """
  Returns the OTP app from the Mix project configuration.
  """
  def otp_app do
    Mix.Project.config() |> Keyword.fetch!(:app)
  end

end
