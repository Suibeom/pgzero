defmodule PGZeroTest.Support.ForwardGenserver do
  use GenServer

  def start(pid) do
    GenServer.start(__MODULE__, pid, name: __MODULE__)
  end

  def init(pid) do
    {:ok, pid}
  end

  def state() do
    GenServer.call(__MODULE__, :state)
  end

  def monitor_scope(scope \\ PGZero) do
    GenServer.call(__MODULE__, {:monitor_scope, scope})
  end

  def monitor(group, scope \\ PGZero) do
    GenServer.call(__MODULE__, {:monitor, group, scope})
  end

  @impl true
  def handle_call({:monitor, group, scope}, _from, state) do
    PGZero.monitor(group, scope)
    {:reply, :ok, state}
  end

  def handle_call({:monitor_scope, scope}, _from, state) do
    PGZero.monitor_scope(scope)
    {:reply, :ok, state}
  end

  def handle_call(:state, _from, state) do
    {:reply, state, state}
  end

  @impl true
  def handle_info(msg, pid) do
    send(pid, msg)
    {:noreply, state}
  end
end
