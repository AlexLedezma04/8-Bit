defmodule Greeter do
  @moduledoc """
  Says hello.
  """

  # Greets someone.
  def hello(name) when is_binary(name) do
    IO.puts("Hello, #{name}")
    {:ok, nil}
  end
end
