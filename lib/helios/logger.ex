defmodule Helios.Logger do
  require Logger

  defmacro __using__(_) do
    quote do
      require Logger
      import Helios.Logger

    end
  end

  defmacro debug(msg) do
    {fun, arity} = __CALLER__.function
    mod = __CALLER__.module
    log_level = Application.get_env(:helios, :log_level, :warn)

    quote do
      if unquote(log_level) in [:debug] do
        Logger.debug("[#{inspect unquote(mod)}:#{unquote(fun)}/#{unquote(arity)}] #{unquote(msg)}")
      end
    end
  end

  defmacro info(msg) do
    log_level = Application.get_env(:helios, :log_level, :warn)

    quote do
      if unquote(log_level) in [:debug, :info] do
        Logger.info("#{unquote(msg)}")
      end
    end
  end

  defmacro warn(msg) do
    log_level = Application.get_env(:helios, :log_level, :warn)

    quote do
      if unquote(log_level) in [:debug, :info, :warn] do
        Logger.warn(unquote(msg))
      end
    end
  end

  defmacro error(msg) do
    log_level = Application.get_env(:helios, :log_level, :warn)

    quote do
      if unquote(log_level) in [:debug, :info, :warn, :error] do
        Logger.error(unquote(msg))
      end
    end
  end
end