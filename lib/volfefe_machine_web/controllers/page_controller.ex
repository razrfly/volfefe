defmodule VolfefeMachineWeb.PageController do
  use VolfefeMachineWeb, :controller

  def home(conn, _params) do
    render(conn, :home)
  end
end
