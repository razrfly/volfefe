defmodule VolfefeMachineWeb.Admin.MarketDetailLive do
  @moduledoc """
  LiveView for market drill-down view.

  Phase 4: Displays detailed market information including:
  - Market metadata and resolution status
  - Score distribution for this market
  - All trades with anomaly scores
  - Top suspicious wallets in this market
  """

  use VolfefeMachineWeb, :live_view

  alias VolfefeMachine.Polymarket

  @impl true
  def mount(%{"condition_id" => condition_id}, _session, socket) do
    market_data = Polymarket.market_detail(condition_id)

    if market_data do
      {:ok,
       socket
       |> assign(:page_title, truncate(market_data.market.question, 50))
       |> assign(:condition_id, condition_id)
       |> assign(:market, market_data.market)
       |> assign(:trades, market_data.trades)
       |> assign(:score_distribution, market_data.score_distribution)
       |> assign(:summary, market_data.summary)
       |> assign(:trades_sort, :anomaly_score)
       |> assign(:trades_sort_order, :desc)}
    else
      {:ok,
       socket
       |> assign(:page_title, "Market Not Found")
       |> assign(:condition_id, condition_id)
       |> assign(:market, nil)
       |> assign(:trades, [])
       |> assign(:score_distribution, %{critical: 0, high: 0, medium: 0, low: 0, normal: 0, total: 0})
       |> assign(:summary, %{total_trades: 0, total_volume: 0, unique_wallets: 0, avg_score: 0, max_score: 0})
       |> assign(:trades_sort, :anomaly_score)
       |> assign(:trades_sort_order, :desc)}
    end
  end

  @impl true
  def handle_params(_params, _url, socket) do
    {:noreply, socket}
  end

  @impl true
  def handle_event("sort_trades", %{"field" => field}, socket) do
    field_atom = String.to_existing_atom(field)
    current_sort = socket.assigns.trades_sort
    current_order = socket.assigns.trades_sort_order

    new_order = if field_atom == current_sort do
      if current_order == :desc, do: :asc, else: :desc
    else
      :desc
    end

    trades = sort_trades(socket.assigns.trades, field_atom, new_order)

    {:noreply,
     socket
     |> assign(:trades_sort, field_atom)
     |> assign(:trades_sort_order, new_order)
     |> assign(:trades, trades)}
  end

  defp sort_trades(trades, field, order) do
    Enum.sort_by(trades, fn trade ->
      value = Map.get(trade, field)
      # Handle nil values by putting them at the end
      case value do
        nil -> if order == :desc, do: -999999, else: 999999
        %Decimal{} -> Decimal.to_float(value)
        _ -> value
      end
    end, order)
  end

  # Template helpers

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
  def format_volume(volume) when is_float(volume) and volume >= 1_000_000, do: "$#{Float.round(volume / 1_000_000, 1)}M"
  def format_volume(volume) when is_float(volume) and volume >= 1_000, do: "$#{Float.round(volume / 1_000, 1)}K"
  def format_volume(volume) when is_float(volume), do: "$#{Float.round(volume, 0)}"
  def format_volume(%Decimal{} = d), do: format_volume(Decimal.to_float(d))
  def format_volume(volume), do: "$#{volume}"

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

  def format_price(nil), do: "N/A"
  def format_price(price) when is_float(price), do: Float.round(price, 2) |> to_string()
  def format_price(%Decimal{} = d), do: Decimal.round(d, 2) |> Decimal.to_string()
  def format_price(n), do: "#{n}"

  def format_wallet(nil), do: "Unknown"
  def format_wallet(address) when byte_size(address) > 10 do
    "#{String.slice(address, 0, 6)}...#{String.slice(address, -4, 4)}"
  end
  def format_wallet(address), do: address

  def score_tier_color(nil), do: :zinc
  def score_tier_color(%Decimal{} = d), do: score_tier_color(Decimal.to_float(d))
  def score_tier_color(score) when score >= 0.9, do: :red
  def score_tier_color(score) when score >= 0.7, do: :amber
  def score_tier_color(score) when score >= 0.5, do: :yellow
  def score_tier_color(score) when score >= 0.3, do: :blue
  def score_tier_color(_), do: :green

  def trade_result_icon(nil), do: "⏳"
  def trade_result_icon(true), do: "✅"
  def trade_result_icon(false), do: "❌"

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
      seconds < 0 -> "in the future"
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

  def format_datetime(nil), do: "N/A"
  def format_datetime(%DateTime{} = dt), do: Calendar.strftime(dt, "%Y-%m-%d %H:%M")
  def format_datetime(%NaiveDateTime{} = dt), do: Calendar.strftime(dt, "%Y-%m-%d %H:%M")

  def truncate(nil, _), do: ""
  def truncate(str, max_length) when is_binary(str) do
    if String.length(str) > max_length do
      String.slice(str, 0, max_length) <> "..."
    else
      str
    end
  end
end
