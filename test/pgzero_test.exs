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

      assert(nil == PGZero.members(Group1, TestScope2))
    end

    test "joining and leaving different groups" do
      PGZero.start_link([TestScope4])
      {:ok, pid_1} = IdleGenserver.start_link()
      PGZero.join(pid_1, Group1, TestScope4)
      PGZero.join(pid_1, Group2, TestScope4)

      assert([_] = PGZero.members(Group1, TestScope4))

      PGZero.leave(pid_1, Group1, TestScope4)

      assert(nil == PGZero.members(Group1, TestScope4))
      assert([_] = PGZero.members(Group2, TestScope4))

      PGZero.leave(pid_1, Group2, TestScope4)

      assert(nil == PGZero.members(Group, TestScope4))
    end
  end

  describe "dead processes are handled correctly" do
    test "a dead process gets cleaned up" do
      PGZero.start_link([TestScope3])

      {:ok, pid_1} = IdleGenserver.start()
      PGZero.join(pid_1, Group1, TestScope3)
      mref = Process.monitor(pid_1)

      Process.exit(pid_1, :kill)
      assert_receive({:DOWN, mref, :process, pid_1, _})

      # Process.sleep(10)

      assert(nil == PGZero.members(Group1, TestScope3))
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

      assert true
    end
  end

  describe "monitors!" do
    test "monitors get join messages from local joins" do
      PGZero.start_link([TestScope6])
      {:ok, pid_1} = IdleGenserver.start()

      PGZero.monitor(Group2, TestScope6)

      PGZero.join(pid_1, Group2, TestScope6)

      assert_receive({_, :join, pid_1, Group2})
    end

    test "monitors get leave messages from local leaves" do
      PGZero.start_link([TestScope7])
      {:ok, pid_1} = IdleGenserver.start()

      PGZero.monitor(Group2, TestScope7)

      PGZero.join(pid_1, Group2, TestScope7)

      PGZero.leave(pid_1, Group2, TestScope7)

      assert_receive(_)

      assert_receive({_, :leave, pid_1, Group2})
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
      {:ok, _} = :rpc.call(node_1, ForwardGenserver, :start, [self()])
      :ok = :rpc.call(node_1, ForwardGenserver, :monitor, [Group1, TestScope8])

      {:ok, pid} =
        :rpc.call(
          node_2,
          IdleGenserver,
          :start,
          []
        )




      :rpc.call(node_2, PGZero, :join, [pid, Group1, TestScope8])

      assert_receive({_, :join, pid, Group1})
    end
  end
end
