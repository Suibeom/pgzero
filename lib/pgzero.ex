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

  def demonitor(mref, group, scope \\ __MODULE__) do
    GenServer.call(scope, {:demonitor, mref, group})
  end

  def monitor_scope(scope \\ __MODULE__) do
    GenServer.call(scope, :monitor_scope)
  end

  def demonitor_scope(mref, scope \\ __MODULE__) do
    GenServer.call(scope, {:demonitor_scope, mref})
  end

  def which_groups(scope \\ __MODULE__) do
    GenServer.call(scope, :which_groups)
  end

  def which_local_groups(scope \\ __MODULE__) do
    GenServer.call(scope, :which_local_groups)
  end

  @impl true
  @doc """
  one pid joining
  """
  def handle_call(
        event = {:join, pid, group},
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

    notify_watchers(event, state)

    {:reply, :ok,
     %{state | pids_local: new_pids_local, groups: new_groups, groups_local: new_groups_local}}
  end

  # One pid leaving; logic broken out into handle_leave so we can reuse it for a local pid going down.

  def handle_call(
        event = {:leave, pid, group},
        _from,
        state
      )
      when is_pid(pid) do
    new_state = handle_local_leave(pid, group, state)

    notify_watchers(event, state)

    {:reply, :ok, new_state}
  end

  def handle_call({:members, group}, _from, state = %ScopeState{groups: groups}) do
    {:reply, Map.get(groups, group, []), state}
  end

  def handle_call({:local_members, group}, _from, state = %ScopeState{groups_local: groups_local}) do
    {:reply, Map.get(groups_local, group, []), state}
  end

  def handle_call(
        :monitor_scope,
        {pid, _},
        state = %ScopeState{groups: groups, scope_monitors: scope_monitors}
      ) do
    mref = Process.monitor(pid)
    {:reply, {mref, groups}, %{state | scope_monitors: Map.put(scope_monitors, mref, pid)}}
  end

  def handle_call(
        {:demonitor_scope, mref},
        {pid, _},
        state = %ScopeState{groups: groups, scope_monitors: scope_monitors}
      ) do
    Process.demonitor(mref)
    {:reply, {mref, groups}, %{state | scope_monitors: Map.delete(scope_monitors, mref)}}
  end

  def handle_call(
        {:monitor, group},
        {pid, _},
        state = %ScopeState{groups: groups, group_monitors: group_monitors}
      ) do
    mref = Process.monitor(pid)

    new_group_monitors =
      case group_monitors[group] do
        nil -> Map.put(group_monitors, group, %{mref => pid})
        map -> Map.update!(group_monitors, group, &Map.put(&1, mref, pid))
      end

    {:reply, {mref, Map.get(groups, group, [])}, %{state | group_monitors: new_group_monitors}}
  end

  def handle_call(
        {:demonitor, mref, group},
        {pid, _},
        state = %ScopeState{group_monitors: group_monitors}
      ) do
    Process.demonitor(mref)
    new_group_monitors = %{group_monitors | group => Map.delete(group_monitors[group], mref)}

    {:reply, :ok, %{state | group_monitors: new_group_monitors}}
  end

  def handle_call(:which_groups, _from, state = %ScopeState{groups: groups}) do
    {:reply, Map.keys(groups), state}
  end

  def handle_call(:which_local_groups, _from, state = %ScopeState{groups_local: groups_local}) do
    {:reply, Map.keys(groups_local), state}
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

  def handle_info(event = {:join, pid, group}, state = %ScopeState{groups: groups}) do
    new_groups =
      groups
      |> Map.update(group, [pid], &[pid | &1])

    notify_watchers(event, state)

    {:noreply, %{state | groups: new_groups}}
  end

  def handle_info(event = {:leave, pid, group}, state = %ScopeState{groups: groups}) do
    new_groups =
      case Map.get(groups, group) do
        [_pid] -> Map.delete(groups, group)
        pids -> Map.put(groups, group, List.delete(pids, pid))
      end

    notify_watchers(event, state)

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
  # handle a local pid going down. N.B., we get one of these for each monitor, not each pid!
  def handle_info(
        {:DOWN, mref, _, pid, _},
        state = %ScopeState{
          pids_local: pids_local,
          group_monitors: group_monitors,
          scope_monitors: scope_monitors
        }
      )
      when node(pid) == node() do
    Process.demonitor(mref)

    new_state =
      case {pids_local[pid], scope_monitors[mref]} do
        # Was this monitor for a pid in a process group?
        {{^mref, groups}, _} ->
          groups
          |> Enum.reduce(
            state,
            fn group, state ->
              handle_local_leave(pid, group, state)
            end
          )

        # Or a scope-wide monitor?
        {_, {^mref, _}} ->
          %{state | scope_monitors: Map.delete(scope_monitors, mref)}

        # Or was it a group monitor?
        _ ->
          new_group_monitors =
            Enum.map(group_monitors, fn {group, monitor_map} ->
              {group, Map.delete(monitor_map, mref)}
            end)
            |> Enum.into(%{})

          %{state | group_monitors: new_group_monitors}
      end

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
    {mref, pid_groups} = pids_local[pid]

    new_pids_local =
      case pid_groups do
        [_] ->
          Process.demonitor(mref)
          Map.delete(pids_local, pid)

        pid_groups ->
          Map.put(pids_local, pid, {mref, List.delete(pid_groups, group)})
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
    for {ref, monitor_pid} <- scope_monitors do
      send(monitor_pid, {ref, verb, pid, group})
    end

    for {ref, monitor_pid} <- Map.get(group_monitors, group, %{}) do
      send(monitor_pid, {ref, verb, pid, group})
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
