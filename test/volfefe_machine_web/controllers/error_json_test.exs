defmodule VolfefeMachineWeb.ErrorJSONTest do
  use VolfefeMachineWeb.ConnCase, async: true

  test "renders 404" do
    assert VolfefeMachineWeb.ErrorJSON.render("404.json", %{}) == %{errors: %{detail: "Not Found"}}
  end

  test "renders 500" do
    assert VolfefeMachineWeb.ErrorJSON.render("500.json", %{}) ==
             %{errors: %{detail: "Internal Server Error"}}
  end
end
