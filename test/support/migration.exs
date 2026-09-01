defmodule Pixelex.Test.Migration do
  use Ecto.Migration

  def up, do: Pixelex.Migration.up()
  def down, do: Pixelex.Migration.down()
end
