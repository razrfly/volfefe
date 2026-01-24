defmodule VolfefeMachineWeb.Admin.MarketAnalysisLive do
  use VolfefeMachineWeb, :live_view

  alias VolfefeMachine.{Content, MarketData}

  @impl true
  def mount(_params, _session, socket) do
    {:ok,
     socket
     |> assign(:page_title, "Market Analysis")
     |> assign(:filter_form, to_form(%{}, as: "filter"))
     |> assign(:filter_significance, "all")
     |> assign(:filter_order, "published_at")
     |> assign(:selected_content_id, nil)
     |> assign(:selected_snapshots, nil)
     |> load_content_list()}
  end

  @impl true
  def handle_params(params, _url, socket) do
    content_id = params["id"]

    socket =
      if content_id do
        case Integer.parse(content_id) do
          {id, ""} ->
            socket
            |> assign(:selected_content_id, id)
            |> load_content_snapshots(id)

          _ ->
            socket
        end
      else
        socket
        |> assign(:selected_content_id, nil)
        |> assign(:selected_snapshots, nil)
      end

    {:noreply, socket}
  end

  @impl true
  def handle_event("update_filter", %{"filter" => filter_params}, socket) do
    significance = Map.get(filter_params, "significance", "all")
    order_by = Map.get(filter_params, "order_by", "published_at")

    {:noreply,
     socket
     |> assign(:filter_significance, significance)
     |> assign(:filter_order, order_by)
     |> load_content_list()}
  end

  @impl true
  def handle_event("select_content", %{"id" => id_str}, socket) do
    case Integer.parse(id_str) do
      {id, ""} ->
        {:noreply, push_patch(socket, to: ~p"/admin/market-analysis?id=#{id}")}

      _ ->
        {:noreply, socket}
    end
  end

  @impl true
  def handle_event("clear_selection", _params, socket) do
    {:noreply, push_patch(socket, to: ~p"/admin/market-analysis")}
  end

  # Private functions

  defp load_content_list(socket) do
    significance = socket.assigns.filter_significance
    order_by =
      case socket.assigns.filter_order do
        "max_z_score" -> :max_z_score
        "published_at" -> :published_at
        _ -> :published_at  # default fallback
      end

    opts = [
      limit: 50,
      order_by: order_by
    ]

    opts =
      if significance != "all" do
        Keyword.put(opts, :min_significance, significance)
      else
        opts
      end

    content_list = MarketData.list_content_with_snapshots(opts)

    assign(socket, :content_list, content_list)
  end

  defp load_content_snapshots(socket, content_id) do
    case Content.get_content(content_id) do
      nil ->
        socket
        |> put_flash(:error, "Content not found")
        |> assign(:selected_content, nil)
        |> assign(:selected_snapshots, nil)

      content ->
        case MarketData.get_content_snapshots(content_id) do
          {:ok, snapshots} ->
            socket
            |> assign(:selected_content, content)
            |> assign(:selected_snapshots, snapshots)

          {:error, :no_snapshots} ->
            socket
            |> put_flash(:warning, "No market snapshots found for this content")
            |> assign(:selected_content, content)
            |> assign(:selected_snapshots, [])
        end
    end
  end

  # Template helpers

  defp format_price(nil), do: "—"

  defp format_price(decimal) do
    decimal
    |> Decimal.to_float()
    |> :erlang.float_to_binary(decimals: 2)
  end

  defp format_percentage(nil), do: "—"

  defp format_percentage(decimal) do
    value = Decimal.to_float(decimal)
    sign = if value >= 0, do: "+", else: ""
    "#{sign}#{:erlang.float_to_binary(value, decimals: 2)}%"
  end

  defp format_z_score(nil), do: "—"

  defp format_z_score(decimal) do
    decimal
    |> Decimal.to_float()
    |> :erlang.float_to_binary(decimals: 2)
  end

  # Catalyst badge color atoms
  def significance_to_color("high"), do: :red
  def significance_to_color("moderate"), do: :amber
  def significance_to_color("noise"), do: :zinc
  def significance_to_color(_), do: :zinc

  def sentiment_to_color("positive"), do: :green
  def sentiment_to_color("negative"), do: :red
  def sentiment_to_color("neutral"), do: :zinc
  def sentiment_to_color(_), do: :zinc

  defp price_change_class(nil), do: ""

  defp price_change_class(decimal) do
    if Decimal.compare(decimal, 0) == :gt do
      "text-green-600 dark:text-green-400"
    else
      "text-red-600 dark:text-red-400"
    end
  end

  defp window_label("before"), do: "Before"
  defp window_label("1hr_after"), do: "1hr After"
  defp window_label("4hr_after"), do: "4hr After"
  defp window_label("24hr_after"), do: "24hr After"
  defp window_label(window), do: window

  defp format_volume(volume) when is_integer(volume) do
    volume
    |> Integer.to_string()
    |> String.reverse()
    |> String.replace(~r/(\d{3})(?=\d)/, "\\1,")
    |> String.reverse()
  end

  defp format_volume(_), do: "—"
end
