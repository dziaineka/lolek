defmodule Lolek.Command do
  @moduledoc """
  Runs external commands without invoking a shell.
  """

  @type result :: {:ok, keyword()} | {:error, term()}

  @spec run(String.t(), [String.t()]) :: result()
  @spec run(String.t(), [String.t()], [term()]) :: result()
  def run(executable, args, options \\ [:sync, :stdout, :stderr]) do
    case System.find_executable(executable) do
      nil -> {:error, "#{executable} executable was not found"}
      executable_path -> :exec.run([executable_path | args], options)
    end
  end
end
