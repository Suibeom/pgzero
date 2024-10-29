# PGZero

A re-implementation of the Erlang module PG in Elixir, for fun and learning purposes. Many optimizations are left out of the current PG code, largely for my own curiosity at how much they help and also to prevent this from being a strict one-to-one port, which wouldn't teach me much.

## Installation

If [available in Hex](https://hex.pm/docs/publish), the package can be installed
by adding `pgzero` to your list of dependencies in `mix.exs`:

```elixir
def deps do
  [
    {:pgzero, "~> 0.1.0"}
  ]
end
```

Documentation can be generated with [ExDoc](https://github.com/elixir-lang/ex_doc)
and published on [HexDocs](https://hexdocs.pm). Once published, the docs can
be found at <https://hexdocs.pm/pgzero>.

