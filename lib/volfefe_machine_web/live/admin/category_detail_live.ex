defmodule VolfefeMachineWeb.Admin.CategoryDetailLive do
  @moduledoc """
  LiveView for category drill-down view.

  Phase 4: Displays detailed category statistics including:
  - 7-day trend chart
  - Score distribution visualization
  - Markets table with sorting/filtering
  - Suspicious wallets leaderboard
  """

  use VolfefeMachineWeb, :live_view

  alias VolfefeMachine.Polymarket

  @impl true
  def mount(%{"category" => category}, _session, socket) do
    if connected?(socket) do
      :timer.send_interval(30_000, self(), :refresh_data)
    end

    {:ok,
     socket
     |> assign(:page_title, "#{String.capitalize(category)} Category")
     |> assign(:category, category)
     |> assign(:date_range, "7d")
     |> assign(:markets_sort, :anomaly_rate)
     |> assign(:markets_sort_order, :desc)
     |> assign(:watched_market_ids, Polymarket.watched_market_ids())
     |> load_data()}
  end

  @impl true
  def handle_params(_params, _url, socket) do
    {:noreply, socket}
  end

  @impl true
  def handle_event("change_date_range", %{"range" => range}, socket) do
    {:noreply,
     socket
     |> assign(:date_range, range)
     |> load_data()}
  end

  @impl true
  def handle_event("sort_markets", %{"field" => field}, socket) do
    field_atom = String.to_existing_atom(field)
    current_sort = socket.assigns.markets_sort
    current_order = socket.assigns.markets_sort_order

    new_order = if field_atom == current_sort do
      if current_order == :desc, do: :asc, else: :desc
    else
      :desc
    end

    markets = sort_markets(socket.assigns.markets, field_atom, new_order)

    {:noreply,
     socket
     |> assign(:markets_sort, field_atom)
     |> assign(:markets_sort_order, new_order)
     |> assign(:markets, markets)}
  end

  @impl true
  def handle_event("toggle_watch", %{"market-id" => market_id}, socket) do
    market_id = String.to_integer(market_id)

    case Polymarket.toggle_watch_market(market_id) do
      {:ok, :watched} ->
        watched_ids = MapSet.put(socket.assigns.watched_market_ids, market_id)
        {:noreply, assign(socket, :watched_market_ids, watched_ids)}

      {:ok, :unwatched} ->
        watched_ids = MapSet.delete(socket.assigns.watched_market_ids, market_id)
        {:noreply, assign(socket, :watched_market_ids, watched_ids)}

      {:error, _} ->
        {:noreply, socket}
    end
  end

  @impl true
  def handle_info(:refresh_data, socket) do
    {:noreply, load_data(socket)}
  end

  defp load_data(socket) do
    category = socket.assigns.category
    date_range = socket.assigns.date_range

    # Load all category data
    stats = Polymarket.category_detail_stats(category, range: date_range)
    trend_data = Polymarket.category_trend_data(category, days: 7)
    markets = Polymarket.category_markets(category, range: date_range, limit: 100)
    wallets = Polymarket.category_wallets(category, range: date_range, limit: 50)

    # Sort markets according to current sort settings
    sorted_markets = sort_markets(markets, socket.assigns.markets_sort, socket.assigns.markets_sort_order)

    # Load ring connection info for top wallets (limit to avoid performance issues)
    wallet_addresses = wallets |> Enum.take(20) |> Enum.map(& &1.wallet_address)
    ring_connections = Polymarket.ring_connections_batch(wallet_addresses)

    socket
    |> assign(:stats, stats)
    |> assign(:trend_data, trend_data)
    |> assign(:markets, sorted_markets)
    |> assign(:wallets, wallets)
    |> assign(:ring_connections, ring_connections)
  end

  defp sort_markets(markets, field, order) do
    Enum.sort_by(markets, &Map.get(&1, field, 0), order)
  end

  # Template helper functions

  def category_icon(category) do
    case to_string(category) do
      "politics" -> "🏛️"
      "crypto" -> "🪙"
      "sports" -> "⚽"
      "entertainment" -> "🎬"
      "science" -> "🔬"
      "business" -> "🏢"
      _ -> "📊"
    end
  end

  def format_volume(nil), do: "$0"
  def format_volume(volume) when volume >= 1_000_000, do: "$#{Float.round(volume / 1_000_000, 1)}M"
  def format_volume(volume) when volume >= 1_000, do: "$#{Float.round(volume / 1_000, 1)}K"
  def format_volume(volume), do: "$#{Float.round(volume, 0)}"

  def format_number(n) when is_integer(n) do
    n
    |> Integer.to_string()
    |> String.reverse()
    |> String.replace(~r/(\d{3})(?=\d)/, "\\1,")
    |> String.reverse()
  end
  def format_number(n), do: "#{n}"

  def format_score(nil), do: "N/A"
  def format_score(score) when is_float(score), do: Float.round(score, 2) |> to_string()
  def format_score(%Decimal{} = d), do: Decimal.round(d, 2) |> Decimal.to_string()
  def format_score(n), do: "#{n}"

  def format_rate(nil), do: "N/A"
  def format_rate(rate), do: "#{rate}%"

  def format_wallet(nil), do: "Unknown"
  def format_wallet(address) when byte_size(address) > 10 do
    "#{String.slice(address, 0, 6)}...#{String.slice(address, -4, 4)}"
  end
  def format_wallet(address), do: address

  def score_tier_color(score) when is_nil(score), do: :zinc
  def score_tier_color(score) when score >= 0.9, do: :red
  def score_tier_color(score) when score >= 0.7, do: :amber
  def score_tier_color(score) when score >= 0.5, do: :yellow
  def score_tier_color(score) when score >= 0.3, do: :blue
  def score_tier_color(_), do: :green

  def wallet_status_color(:confirmed_insider), do: :red
  def wallet_status_color(:under_investigation), do: :amber
  def wallet_status_color(_), do: :zinc

  def wallet_status_label(:confirmed_insider), do: "Confirmed"
  def wallet_status_label(:under_investigation), do: "Investigating"
  def wallet_status_label(_), do: nil

  def sort_indicator(current_sort, field, order) do
    if current_sort == field do
      if order == :desc, do: "↓", else: "↑"
    else
      ""
    end
  end

  def relative_time(nil), do: "N/A"
  def relative_time(%DateTime{} = dt) do
    seconds = DateTime.diff(DateTime.utc_now(), dt)
    cond do
      seconds < 0 -> "just now"
      seconds < 60 -> "#{seconds}s ago"
      seconds < 3600 -> "#{div(seconds, 60)}m ago"
      seconds < 86400 -> "#{div(seconds, 3600)}h ago"
      true -> "#{div(seconds, 86400)}d ago"
    end
  end
  def relative_time(%NaiveDateTime{} = dt) do
    {:ok, datetime} = DateTime.from_naive(dt, "Etc/UTC")
    relative_time(datetime)
  end

  def truncate(nil, _), do: ""
  def truncate(str, max_length) when is_binary(str) do
    if String.length(str) > max_length do
      String.slice(str, 0, max_length) <> "..."
    else
      str
    end
  end
end
