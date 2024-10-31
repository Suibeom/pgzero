defmodule PGZeroTest do
  use ExUnit.Case
  alias PGZeroTest.Support.IdleGenserver
  alias PGZeroTest.Support.ForwardGenserver
  doctest PGZero

  describe "joining and leaving locally" do
    test "join works" do
      PGZero.start_link([TestScope1])
      {:ok, pid_1} = IdleGenserver.start_link()
      PGZero.join(pid_1, Group1, TestScope1)

      assert([_] = PGZero.members(Group1, TestScope1))
    end

    test "join and then leave works" do
      PGZero.start_link([TestScope2])

      {:ok, pid_1} = IdleGenserver.start_link()
      PGZero.join(pid_1, Group1, TestScope2)

      assert([_] = PGZero.members(Group1, TestScope2))

      PGZero.leave(pid_1, Group1, TestScope2)

      assert([] == PGZero.members(Group1, TestScope2))
    end

    test "joining and leaving different groups" do
      PGZero.start_link([TestScope4])
      {:ok, pid_1} = IdleGenserver.start_link()
      PGZero.join(pid_1, Group1, TestScope4)
      PGZero.join(pid_1, Group2, TestScope4)

      assert([_] = PGZero.members(Group1, TestScope4))

      PGZero.leave(pid_1, Group1, TestScope4)

      assert([] == PGZero.members(Group1, TestScope4))
      assert([_] = PGZero.members(Group2, TestScope4))

      PGZero.leave(pid_1, Group2, TestScope4)

      assert([] == PGZero.members(Group, TestScope4))
    end
  end

  describe "dead processes are handled correctly" do
    test "a dead process gets cleaned up" do
      PGZero.start_link([TestScope3])

      {:ok, pid_1} = IdleGenserver.start()
      PGZero.join(pid_1, Group1, TestScope3)
      mref = Process.monitor(pid_1)

      Process.exit(pid_1, :kill)
      assert_receive({:DOWN, ^mref, :process, ^pid_1, _})

      assert([] == PGZero.members(Group1, TestScope3))
    end
  end

  describe "remote processes" do
    test "nodes successfully tell each other about processes which have joined" do
      {:ok, cluster} = LocalCluster.start_link(3)
      {:ok, [node | _] = nodes} = LocalCluster.nodes(cluster)

      for node <- nodes do
        :rpc.call(node, PGZero, :start, [[TestGroup5]])
      end

      for node <- nodes do
        # Workaround Alert: LocalCluster's startup does not shoot off :nodeup messages so we need to do that ourselves.
        for node_2 <- nodes, node_2 != node do
          send({TestGroup5, node}, {:nodeup, node_2})
        end

        # Workaround Alert

        {:ok, pid} =
          :rpc.call(
            node,
            IdleGenserver,
            :start,
            []
          )

        :ok =
          :rpc.call(
            node,
            PGZero,
            :join,
            [pid, Group4, TestGroup5]
          )
      end

      assert [_, _, _] = :rpc.call(node, PGZero, :members, [Group4, TestGroup5])
    end

    test "nodes successfully tell each other about processes which have left" do
      {:ok, cluster} = LocalCluster.start_link(3)
      {:ok, [node | _] = nodes} = LocalCluster.nodes(cluster)

      for node <- nodes do
        :rpc.call(node, PGZero, :start, [[TestGroup14]])
      end

      for node <- nodes do
        # Workaround Alert: LocalCluster's startup does not shoot off :nodeup messages so we need to do that ourselves.
        for node_2 <- nodes, node_2 != node do
          send({TestGroup14, node}, {:nodeup, node_2})
        end

        # Workaround Alert

        {:ok, pid} =
          :rpc.call(
            node,
            IdleGenserver,
            :start,
            []
          )

        :ok =
          :rpc.call(
            node,
            PGZero,
            :join,
            [pid, Group4, TestGroup14]
          )

        :ok =
          :rpc.call(
            node,
            PGZero,
            :leave,
            [pid, Group4, TestGroup14]
          )
      end

      assert [] = :rpc.call(node, PGZero, :members, [Group4, TestGroup14])
    end

    test "which_groups and which_local_groups work and update properly" do
      {:ok, cluster} = LocalCluster.start_link(2)
      {:ok, [node_1, node_2] = nodes} = LocalCluster.nodes(cluster)

      for node <- nodes do
        :rpc.call(node, PGZero, :start, [[TestGroup15]])
      end

      for node <- nodes do
        # Workaround Alert: LocalCluster's startup does not shoot off :nodeup messages so we need to do that ourselves.
        for node_2 <- nodes, node_2 != node do
          send({TestGroup15, node}, {:nodeup, node_2})
        end

        # Workaround Alert
      end

      {:ok, pid_1} =
        :rpc.call(
          node_1,
          IdleGenserver,
          :start,
          []
        )

      :ok =
        :rpc.call(
          node_1,
          PGZero,
          :join,
          [pid_1, Group4, TestGroup15]
        )

      {:ok, pid_2} =
        :rpc.call(
          node_2,
          IdleGenserver,
          :start,
          []
        )

      :ok =
        :rpc.call(
          node_2,
          PGZero,
          :join,
          [pid_2, Group4, TestGroup15]
        )

      assert [Group4] = :rpc.call(node_1, PGZero, :which_groups, [TestGroup15])
      assert [Group4] = :rpc.call(node_1, PGZero, :which_local_groups, [TestGroup15])

      :ok =
        :rpc.call(
          node_1,
          PGZero,
          :leave,
          [pid_1, Group4, TestGroup15]
        )

      assert [Group4] = :rpc.call(node_1, PGZero, :which_groups, [TestGroup15])
      assert [] = :rpc.call(node_1, PGZero, :which_local_groups, [TestGroup15])
    end

    test "joining a cluster with a group that already exists" do
      {:ok, cluster} = LocalCluster.start_link(3)
      {:ok, [node_1, node_2, node_3] = nodes} = LocalCluster.nodes(cluster)

      for node <- nodes do
        :rpc.call(node, PGZero, :start, [[TestGroup18]])
      end

      for node <- nodes do
        {:ok, pid} =
          :rpc.call(
            node,
            IdleGenserver,
            :start,
            []
          )

        :ok =
          :rpc.call(
            node,
            PGZero,
            :join,
            [pid, Group4, TestGroup18]
          )
      end

      assert [_] = :rpc.call(node_1, PGZero, :members, [Group4, TestGroup18])
      assert [_] = :rpc.call(node_2, PGZero, :members, [Group4, TestGroup18])
      assert [_] = :rpc.call(node_3, PGZero, :members, [Group4, TestGroup18])

      # By this point, none of the PGZero's has seen any :nodeup messages, so they are effectively unconnected.
      # We send them by hand here to trigger the agents to see eachother.
      for node <- nodes do
        for node_2 <- nodes, node_2 != node do
          send({TestGroup18, node}, {:nodeup, node_2})
        end
      end

      Process.sleep(10)

      assert [_, _, _] = :rpc.call(node_1, PGZero, :members, [Group4, TestGroup18])
    end

    test "knocking out a node causes its process group members to leave" do
      {:ok, cluster} = LocalCluster.start_link(3)
      {:ok, [node_1, _, node_3] = nodes} = LocalCluster.nodes(cluster)

      for node <- nodes do
        :rpc.call(node, PGZero, :start, [[TestGroup19]])
      end

      for node <- nodes do
        # Workaround Alert: LocalCluster's startup does not shoot off :nodeup messages so we need to do that ourselves.
        for node_2 <- nodes, node_2 != node do
          send({TestGroup19, node}, {:nodeup, node_2})
        end

        # Workaround Alert
        {:ok, pid} =
          :rpc.call(
            node,
            IdleGenserver,
            :start,
            []
          )

        :ok =
          :rpc.call(
            node,
            PGZero,
            :join,
            [pid, Group4, TestGroup19]
          )
      end

      LocalCluster.stop(cluster, node_3)

      assert [_, _] = :rpc.call(node_1, PGZero, :members, [Group4, TestGroup19])
    end
  end

  describe "monitors!" do
    test "monitors get join messages from local joins" do
      PGZero.start_link([TestScope6])
      {:ok, pid_1} = IdleGenserver.start()

      PGZero.monitor(Group2, TestScope6)

      PGZero.join(pid_1, Group2, TestScope6)

      assert_receive({_, :join, ^pid_1, Group2})
    end

    test "monitors get leave messages from local leaves" do
      PGZero.start_link([TestScope7])
      {:ok, pid_1} = IdleGenserver.start()

      PGZero.monitor(Group2, TestScope7)

      PGZero.join(pid_1, Group2, TestScope7)

      PGZero.leave(pid_1, Group2, TestScope7)

      assert_receive(_)

      assert_receive({_, :leave, ^pid_1, Group2})
    end

    test "group monitors are properly cleaned up on demonitor" do
      PGZero.start_link([TestScope9])
      {:ok, mref} = PGZero.monitor(Group1, TestScope9)
      PGZero.demonitor(mref, Group1, TestScope9)

      {:ok, pid_1} = IdleGenserver.start()
      PGZero.join(pid_1, Group1, TestScope9)

      refute_receive(_)
    end

    test "group monitors are properly cleaned up on process death" do
      {:ok, pgzero} = PGZero.start_link([TestScope10])
      {:ok, pid_1} = ForwardGenserver.start(self())
      ForwardGenserver.monitor(Group1, TestScope10)

      Process.exit(pid_1, :kill)

      assert(%{} = :sys.get_state(pgzero).group_monitors)
    end

    test "scope monitors are properly cleaned up on demonitor" do
      PGZero.start_link([TestScope11])
      {:ok, mref} = PGZero.monitor_scope(TestScope11)
      PGZero.demonitor_scope(mref, TestScope11)

      {:ok, pid_1} = IdleGenserver.start()
      PGZero.join(pid_1, Group1, TestScope11)

      refute_receive(_)
    end

    test "scope monitors are properly cleaned up on process death" do
      {:ok, pgzero} = PGZero.start_link([TestScope12])
      {:ok, pid_1} = ForwardGenserver.start(self())
      ForwardGenserver.monitor_scope(TestScope12)

      Process.exit(pid_1, :kill)

      assert(%{} = :sys.get_state(pgzero).scope_monitors)
    end

    test "monitors get join messages from remote joins" do
      {:ok, cluster} = LocalCluster.start_link(2)
      {:ok, [node_1, node_2] = nodes} = LocalCluster.nodes(cluster)

      for node <- nodes do
        :rpc.call(node, PGZero, :start, [[TestScope8]])
      end

      for node <- nodes do
        # Workaround Alert: LocalCluster's startup does not shoot off :nodeup messages so we need to do that ourselves.
        for node_2 <- nodes, node_2 != node do
          send({TestScope8, node}, {:nodeup, node_2})
        end

        # Workaround Alert
      end

      # Set up our process to monitor things.
      {:ok, fws} = :rpc.call(node_1, ForwardGenserver, :start, [self()])
      :ok = :rpc.call(node_1, ForwardGenserver, :monitor, [Group1, TestScope8])

      {:ok, pid} =
        :rpc.call(
          node_2,
          IdleGenserver,
          :start,
          []
        )

      :rpc.call(node_2, PGZero, :join, [pid, Group1, TestScope8])

      assert_receive({_, :join, ^pid, Group1})
    end
  end
end
