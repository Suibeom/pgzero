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
  alias PGZero.ScopeState

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

  def start_link([scope]) do
    GenServer.start_link(__MODULE__, [scope], name: scope)
  end

  def start_link([]) do
    scope = __MODULE__
    GenServer.start_link(__MODULE__, [scope], name: scope)
  end

  def start([scope]) do
    GenServer.start(__MODULE__, [scope], name: scope)
  end

  def start([]) do
    scope = __MODULE__
    GenServer.start(__MODULE__, [scope], name: scope)
  end

  @impl true
  def init([scope]) do
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

  def monitor(group, scope \\ __MODULE__) do
    GenServer.call(scope, {:monitor, group})
  end

  def monitor_scope(scope \\ __MODULE__) do
    GenServer.call(scope, :monitor_scope)
  end

  def state(scope \\ __MODULE__) do
    GenServer.call(scope, :state)
  end

  @impl true
  @doc """
  one pid joining
  """
  def handle_call(
        action = {:join, pid, group},
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
        true -> Map.update!(pids_local, pid, fn {ref, groups} -> {ref, [group | groups]} end)
        false -> Map.put(pids_local, pid, {Process.monitor(pid), [group]})
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

    notify_watchers(action, state)

    {:reply, :ok,
     %{state | pids_local: new_pids_local, groups: new_groups, groups_local: new_groups_local}}
  end

  # One pid leaving; logic broken out into handle_leave so we can reuse it for a local pid going down.

  def handle_call(
        action = {:leave, pid, group},
        _from,
        state
      )
      when is_pid(pid) do
    new_state = handle_local_leave(pid, group, state)

    notify_watchers(action, state)

    {:reply, :ok, new_state}
  end

  def handle_call({:members, group}, _from, state = %ScopeState{groups: groups}) do
    {:reply, groups[group], state}
  end

  def handle_call({:local_members, group}, _from, state = %ScopeState{groups_local: groups_local}) do
    {:reply, groups_local[group], state}
  end

  def handle_call(:monitor_scope, {pid, _}, state = %ScopeState{scope_monitors: scope_monitors}) do
    {:reply, :ok, %{state | scope_monitors: Map.put(scope_monitors, Process.monitor(pid), pid)}}
  end

  def handle_call(
        {:monitor, group},
        {pid, _},
        state = %ScopeState{group_monitors: group_monitors}
      ) do
    new_group_monitors =
      case group_monitors[group] do
        nil -> Map.put(group_monitors, group, %{Process.monitor(pid) => pid})
        map -> Map.update!(group_monitors, group, &Map.put(&1, Process.monitor(pid), pid))
      end

    {:reply, :ok, %{state | group_monitors: new_group_monitors}}
  end

  def handle_call(:state, _from, state) do
    {:reply, state, state}
  end

  # nodes joining, send discover message!
  @impl true
  def handle_info({:nodeup, node}, %{scope: scope} = state) do
    send({scope, node}, {:discover, self()})
    {:noreply, state}
  end

  def handle_info({:nodedown, _node}, state) do
    # don't worry about this one
    {:noreply, state}
  end

  # These get sent whenever a new node comes up.

  def handle_info(
        {:discover, pid},
        state = %ScopeState{groups_local: groups_local, remotes: remotes}
      ) do
    send(pid, {:sync, node(), groups_local})

    new_remotes =
      case pid in Map.keys(remotes) do
        # do we know them?
        true -> state
        false -> Map.put(remotes, pid, Process.monitor(pid))
      end

    {:noreply, %{state | remotes: new_remotes}}
  end

  def handle_info(action = {:join, pid, group}, state = %ScopeState{groups: groups}) do
    new_groups =
      groups
      |> Map.update(group, [pid], &[pid | &1])

    notify_watchers(action, state)

    {:noreply, %{state | groups: new_groups}}
  end

  def handle_info(action = {:leave, pid, group}, state = %ScopeState{groups: groups}) do
    new_groups =
      case Map.get(groups, group) do
        [_pid] -> Map.delete(groups, group)
        pids -> Map.put(groups, group, List.delete(pids, pid))
      end

    notify_watchers(action, state)

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

  @impl true
  # handle a local pid going down.
  def handle_info({:DOWN, _mref, _, pid, _}, state = %ScopeState{pids_local: pids_local})
      when node(pid) == node() do
    # We can do exactly the same thing as if the pid left all of its groups
    {ref, groups} = pids_local[pid]
    Process.demonitor(ref)

    new_state =
      groups
      |> Enum.reduce(
        state,
        fn group, state ->
          handle_local_leave(pid, group, state)
        end
      )

    {:noreply, new_state}
  end

  # Handle a remote node going down.
  def handle_info({:DOWN, mref, _, pid, _}, state = %ScopeState{groups: groups, remotes: remotes}) do
    # PG stashes a complete copy of groups_local alongside the monitor refs in its remotes dictionary,
    # so this step can be a lot more efficient for it, in case nodes are falling off the planet frequently.
    # We'll just run through groups and pids and leave them.

    remote_node = node(pid)
    Process.demonitor(mref)

    group_pid_list =
      for group <- Map.keys(groups),
          pid <- groups[group],
          node(pid) == remote_node,
          do: {group, pid}

    new_state =
      group_pid_list
      |> Enum.reduce(
        state,
        fn {group, pid}, state ->
          handle_remote_leave(pid, group, state)
        end
      )

    {:noreply, %{new_state | remotes: Map.delete(remotes, pid)}}
  end

  defp handle_local_leave(
         pid,
         group,
         state = %ScopeState{
           groups: groups,
           groups_local: groups_local,
           pids_local: pids_local,
           remotes: remotes
         }
       ) do
    {ref, pid_groups} = pids_local[pid]

    new_pids_local =
      case pid_groups do
        [_] ->
          Process.demonitor(ref)
          Map.delete(pids_local, pid)

        pid_groups ->
          Map.put(pids_local, pid, {ref, List.delete(pid_groups, group)})
      end

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

    %{state | pids_local: new_pids_local, groups: new_groups, groups_local: new_groups_local}
  end

  defp handle_remote_leave(pid, group, state = %ScopeState{groups: groups}) do
    new_groups =
      case Map.get(groups, group) do
        [_pid] -> Map.delete(groups, group)
        pids -> Map.put(groups, group, List.delete(pids, pid))
      end

    %{state | groups: new_groups}
  end

  def notify_watchers(
        {verb, pid, group},
        state = %ScopeState{scope_monitors: scope_monitors, group_monitors: group_monitors}
      ) do
    for {ref, pid} <- scope_monitors do
      send(pid, {ref, verb, pid, group})
    end

    for {ref, pid} <- Map.get(group_monitors, group, %{}) do
      send(pid, {ref, verb, pid, group})
    end
  end

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
