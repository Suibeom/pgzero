defmodule PGZeroTest.Support.IdleGenserver do
  use GenServer

  def start_link() do
    GenServer.start_link(__MODULE__, [])
  end

  def start() do
    GenServer.start(__MODULE__, [])
  end

  def init(_) do
    {:ok, []}
  end
end
