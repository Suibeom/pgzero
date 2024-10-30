defmodule PGZeroTest do
  use ExUnit.Case
  alias PGZeroTest.Support.IdleGenserver
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
      # assert ([] = PGZero.state)

      Process.exit(pid_1, :kill)
      assert_receive({:DOWN, mref, :process, pid_1, _})

      # Process.sleep(10)

      assert(nil == PGZero.members(Group1, TestScope3))
    end
  end

  describe "remote processes" do
    test "thingy" do
      {:ok, cluster} = LocalCluster.start_link(3)
      {:ok, [node | _] = nodes} = LocalCluster.nodes(cluster)

      for node <- nodes do
        #Workaround Alert: LocalCluster's startup does not shoot off :nodeup messages so we need to do that ourselves.
        for node_2 <- nodes, node_2 != node do
          send({PGZero, node}, {:nodeup, node_2})
        end
        #Workaround Alert

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
            [pid, Group4]
          )
      end


      assert [_, _, _] = :rpc.call(node, PGZero, :members, [Group4])

      assert true
    end
  end
end
