defmodule Pixelex.Test.Layouts do
  @moduledoc false
  use Phoenix.Component

  def render("root.html", assigns) do
    ~H"""
    <!DOCTYPE html>
    <html lang="en">
      <head><meta charset="utf-8" /><title>test</title></head>
      <body>{@inner_content}</body>
    </html>
    """
  end

  def render("live.html", assigns), do: ~H"{@inner_content}"
end
