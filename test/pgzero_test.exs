defmodule PGZeroTest do
  use ExUnit.Case
  alias PGZeroTest.Support.IdleGenserver
  doctest PGZero

  describe "joining and leaving locally" do
    test "join works" do
    PGZero.start_link()

    {:ok, pid_1} = IdleGenserver.start_link()
    PGZero.join(pid_1, Group1)

    assert(
      [_] = PGZero.members(Group1)
    )

    end
    test "join and then leave works" do
      PGZero.start_link()

      {:ok, pid_1} = IdleGenserver.start_link()
      PGZero.join(pid_1, Group1)

      assert(
        [_] = PGZero.members(Group1)
      )

      PGZero.leave(pid_1, Group1)

      assert(
        nil = PGZero.members(Group1)
      )

      end
  end


end
