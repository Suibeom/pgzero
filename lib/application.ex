defmodule PGZeroAgent do
  use Application

  def start(_, args) do
    children = [{PGZero, args}]
    Supervisor.start_link(children, strategy: :one_for_one)
  end
end
