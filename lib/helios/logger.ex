defmodule Helios.Logger do
  @moduledoc false
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

    quote do
      if Application.get_env(:helios, :log_level, :warn) in [:debug] do
        Logger.debug(fn -> "[#{inspect unquote(mod)}:#{unquote(fun)}/#{unquote(arity)}] #{unquote(msg)}" end)
      end
    end
  end

  defmacro info(msg) do
    quote do
      if Application.get_env(:helios, :log_level, :warn) in [:debug, :info] do
        Logger.info("#{unquote(msg)}")
      end
    end
  end

  defmacro warn(msg) do

    quote do
      if Application.get_env(:helios, :log_level, :warn) in [:debug, :info, :warn] do
        Logger.warn(unquote(msg))
      end
    end
  end

  defmacro error(msg) do
    quote do
      if Application.get_env(:helios, :log_level, :warn) in [:debug, :info, :warn, :error] do
        Logger.error(unquote(msg))
      end
    end
  end
end
