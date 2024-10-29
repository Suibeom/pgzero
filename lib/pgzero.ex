defmodule PGZero do
  use GenServer

  @moduledoc """

  Simplest version to support all functionality;
      join/2,
      leave/2,
      monitor_scope/0,
      monitor_scope/1,
      monitor/1,
      monitor/2,
      demonitor/1,
      demonitor/2,
      get_members/1,
      get_local_members/1,
      which_groups/0,
      which_local_groups/0
  """

  @doc """
  Very different data model to what pg has currently;
  groups: map from groups to pids
  groups_local: same, but only local members
  local_pids: map from local pids to groups (and monitors)
  monitors: ?? undetermined structure to help deal with monitors.
  remotes: pids and monitors of remote nodes also running my scope.
  """
  defmodule ScopeState do
    defstruct scope: __MODULE__,
              groups: %{},
              groups_local: %{},
              pids_local: %{},
              scope_monitors: %{},
              group_monitors: %{},
              remotes: %{}
  end

  def start_link(scope \\ __MODULE__) do
    GenServer.start_link(__MODULE__, [scope], name: scope)
  end

  @impl true
  def init(scope) do
    :net_kernel.monitor_nodes(true)
    # subscribes me to :nodeup and :nodedown message, but we only need :nodeup.
    {:ok, %ScopeState{scope: scope}}
  end

  @doc """
  The call signature for this function is a little different to PG's signature to make it more composible and Elixirish.
  All pids must be local to the genserver we're calling
  """
  def join(pids, group, scope \\ __MODULE__) do
    :ok = ensure_all_local(pids)
    GenServer.call(scope, {:join, pids, group})
  end

  def leave(pids, group, scope \\ __MODULE__) do
    :ok = ensure_all_local(pids)
    GenServer.call(scope, {:leave, pids, group})
  end

  def members(group, scope \\ __MODULE__) do
    GenServer.call(scope, {:members, group})
  end

  def local_members(group, scope \\ __MODULE__) do
    GenServer.call(scope, {:local_members, group})
  end

  @impl true
  @doc """
  one pid joining
  """
  def handle_call(
        {:join, pid, group},
        _from,
        state = %ScopeState{
          groups: groups,
          groups_local: groups_local,
          pids_local: pids_local,
          remotes: remotes
        }
      )
      when is_pid(pid) do
    new_pids_local =
      case Map.has_key?(pids_local, pid) do
        true -> Map.update!(pids_local, pid, &[pid | &1])
        false -> Map.put(pids_local, pid, Process.monitor(pid))
      end

    new_groups =
      groups
      |> Map.update(group, [pid], &[pid | &1])

    new_groups_local =
      groups_local
      |> Map.update(group, [pid], &[pid | &1])

    # Somewhere here we'll need to send a `sync` message.
    Enum.map(
      Map.keys(remotes),
      fn remote -> send(remote, {:join, pid, group}) end
    )

    {:reply, :ok,
     %{state | pids_local: new_pids_local, groups: new_groups, groups_local: new_groups_local}}
  end

  # One pid leaving

  def handle_call(
        {:leave, pid, group},
        _from,
        state = %ScopeState{
          groups: groups,
          groups_local: groups_local,
          pids_local: pids_local,
          remotes: remotes
        }
      )
      when is_pid(pid) do
    ref = pids_local[pid]

    Process.demonitor(ref, [:flush])

    new_pids_local = Map.delete(pids_local, pid)

    new_groups =
      case Map.get(groups, group) do
        [_pid] -> Map.delete(groups, group)
        pids -> Map.put(groups, group, List.delete(pids, pid))
      end

    new_groups_local =
      case Map.get(groups_local, group) do
        [_pid] -> Map.delete(groups_local, group)
        pids -> Map.put(groups_local, group, List.delete(pids, pid))
      end

    # Somewhere here we send sync messages.
    Enum.map(
      Map.keys(remotes),
      fn remote -> send(remote, {:leave, pid, group}) end
    )

    {:reply, :ok,
     %{state | pids_local: new_pids_local, groups: new_groups, groups_local: new_groups_local}}
  end

  def handle_call({:members, group}, _from, state = %ScopeState{groups: groups}) do
    {:reply, groups[group], state}
  end

  def handle_call({:local_members, group}, _from, state = %ScopeState{groups_local: groups_local}) do
    {:reply, groups_local[group], state}
  end

  # nodes joining, send discover message!
  @impl true
  def handle_info({:nodeup, node}, %{scope: scope} = state) do
    send({node, scope}, {:discover, self()})
    {:noreply, state}
  end

  # These get sent whenever a new node comes up.
  def handle_info(
        {:discover, pid},
        state = %ScopeState{groups_local: groups_local, remotes: remotes}
      ) do
    # sync goes here! Send the person we just got messaged by all the local pids we have.
    send(pid, {:sync, node(), groups_local})

    new_state =
      case pid in Map.keys(remotes) do
        # do we know them?
        true -> state
        false -> %{state | remotes: %{remotes | pid => Process.monitor(pid)}}
      end

    {:noreply, new_state}
  end

  def handle_info({:join, pid, group}, state = %ScopeState{groups: groups}) do
    new_groups =
      groups
      |> Map.update(group, [pid], &[pid | &1])

    {:noreply, %{state | groups: new_groups}}
  end

  def handle_info({:leave, pid, group}, state = %ScopeState{groups: groups}) do
    new_groups =
      case Map.get(groups, group) do
        [_pid] -> Map.delete(groups, group)
        pids -> Map.put(groups, group, List.delete(pids, pid))
      end

    {:noreply, %{state | groups: new_groups}}
  end

  def handle_info({:sync, node, remote_groups}, state = %ScopeState{groups: groups}) do
    remote_empty_groups = Map.keys(groups) -- Map.keys(remote_groups)
    new_groups = Map.keys(remote_groups) -- Map.keys(groups)
    current_groups = Map.keys(remote_groups) -- new_groups

    new_groups =
      %{}
      |> Map.merge(
        for key <- remote_empty_groups, into: %{} do
          {key, Enum.filter(groups[key], &(node(&1) != node))}
        end
      )
      |> Map.merge(
        for key <- new_groups, into: %{} do
          {key, remote_groups[key]}
        end
      )
      |> Map.merge(
        for key <- current_groups, into: %{} do
          {key,
           Enum.filter(groups[key], &(node(&1) != node)) ++
             remote_groups[key]}
        end
      )

    {:noreply, %{state | groups: new_groups}}
  end

  # @impl true
  # def handle_info({'DOWN', mref, _, pid, _}, state) do
  # end

  defp ensure_all_local([]), do: :ok

  defp ensure_all_local([pid | rest]) do
    if node(pid) != node() do
      throw({:nolocal, pid})
    end

    ensure_all_local(rest)
  end

  defp ensure_all_local(pid) do
    if node(pid) != node() do
      throw({:nolocal, pid})
    end

    :ok
  end
end
