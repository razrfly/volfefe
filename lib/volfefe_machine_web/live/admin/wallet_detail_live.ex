defmodule VolfefeMachineWeb.Admin.WalletDetailLive do
  @moduledoc """
  LiveView for wallet investigation view.

  Phase 4/5: Displays complete wallet profile including:
  - Wallet summary and risk indicators
  - Z-score breakdown visualization
  - Trade history with scores
  - Category breakdown
  - Investigation actions
  """

  use VolfefeMachineWeb, :live_view

  import LiveToast
  alias VolfefeMachine.Polymarket

  @impl true
  def mount(%{"address" => address}, _session, socket) do
    wallet_data = Polymarket.wallet_detail(address)
    ring_info = Polymarket.ring_connection_info(address)
    ring_members = Polymarket.get_ring_members(address, limit: 10)

    investigation_notes = Polymarket.get_investigation_notes(address)

    if wallet_data do
      {:ok,
       socket
       |> assign(:page_title, "Wallet Investigation")
       |> assign(:address, address)
       |> assign(:wallet, wallet_data)
       |> assign(:trades, wallet_data.trades)
       |> assign(:summary, wallet_data.summary)
       |> assign(:status, wallet_data.status)
       |> assign(:candidate, wallet_data.candidate)
       |> assign(:confirmed_insider, wallet_data.confirmed_insider)
       |> assign(:zscore_breakdown, wallet_data.zscore_breakdown)
       |> assign(:category_breakdown, wallet_data.category_breakdown)
       |> assign(:ring_info, ring_info)
       |> assign(:ring_members, ring_members)
       |> assign(:show_note_modal, false)
       |> assign(:note_form, %{"note_text" => "", "note_type" => "general"})
       |> assign(:investigation_notes, investigation_notes)}
    else
      {:ok,
       socket
       |> assign(:page_title, "Wallet Not Found")
       |> assign(:address, address)
       |> assign(:wallet, nil)
       |> assign(:trades, [])
       |> assign(:summary, nil)
       |> assign(:status, :unknown)
       |> assign(:candidate, nil)
       |> assign(:confirmed_insider, nil)
       |> assign(:zscore_breakdown, nil)
       |> assign(:category_breakdown, %{})
       |> assign(:ring_info, %{connected: false})
       |> assign(:ring_members, %{members: [], total_count: 0})
       |> assign(:show_note_modal, false)
       |> assign(:note_form, %{"note_text" => "", "note_type" => "general"})
       |> assign(:investigation_notes, investigation_notes)}
    end
  end

  @impl true
  def handle_params(_params, _url, socket) do
    {:noreply, socket}
  end

  @impl true
  def handle_event("confirm_insider", _params, socket) do
    address = socket.assigns.address

    case Polymarket.confirm_insider_from_wallet(address, %{
      source: "manual_review",
      confidence: "high",
      notes: "Confirmed from dashboard investigation"
    }) do
      {:ok, _insider} ->
        wallet_data = Polymarket.wallet_detail(address)
        {:noreply,
         socket
         |> assign(:wallet, wallet_data)
         |> assign(:status, wallet_data.status)
         |> assign(:confirmed_insider, wallet_data.confirmed_insider)
         |> put_toast(:success, "Wallet confirmed as insider")}

      {:error, reason} ->
        {:noreply, put_toast(socket, :error, "Failed to confirm: #{inspect(reason)}")}
    end
  end

  @impl true
  def handle_event("dismiss_wallet", _params, socket) do
    case socket.assigns.candidate do
      nil ->
        {:noreply, put_toast(socket, :info, "No candidate to dismiss")}

      candidate ->
        case Polymarket.dismiss_candidate(candidate, "Dismissed from investigation view", "admin") do
          {:ok, _} ->
            wallet_data = Polymarket.wallet_detail(socket.assigns.address)
            {:noreply,
             socket
             |> assign(:wallet, wallet_data)
             |> assign(:status, wallet_data.status)
             |> assign(:candidate, wallet_data.candidate)
             |> put_toast(:success, "Candidate dismissed")}

          {:error, reason} ->
            {:noreply, put_toast(socket, :error, "Failed to dismiss: #{inspect(reason)}")}
        end
    end
  end

  @impl true
  def handle_event("start_investigation", _params, socket) do
    case socket.assigns.candidate do
      nil ->
        {:noreply, put_toast(socket, :info, "No candidate to investigate")}

      candidate ->
        case Polymarket.start_investigation(candidate, "admin") do
          {:ok, _} ->
            wallet_data = Polymarket.wallet_detail(socket.assigns.address)
            {:noreply,
             socket
             |> assign(:wallet, wallet_data)
             |> assign(:status, wallet_data.status)
             |> assign(:candidate, wallet_data.candidate)
             |> put_toast(:success, "Investigation started")}

          {:error, reason} ->
            {:noreply, put_toast(socket, :error, "Failed to start investigation: #{inspect(reason)}")}
        end
    end
  end

  @impl true
  def handle_event("show_note_modal", _params, socket) do
    {:noreply, assign(socket, :show_note_modal, true)}
  end

  @impl true
  def handle_event("close_note_modal", _params, socket) do
    {:noreply,
     socket
     |> assign(:show_note_modal, false)
     |> assign(:note_form, %{"note_text" => "", "note_type" => "general"})}
  end

  @impl true
  def handle_event("add_note", %{"note_text" => note_text, "note_type" => note_type}, socket) do
    address = socket.assigns.address

    case Polymarket.add_wallet_investigation_note(address, note_text, note_type: note_type) do
      {:ok, _note} ->
        notes = Polymarket.get_investigation_notes(address)
        {:noreply,
         socket
         |> assign(:investigation_notes, notes)
         |> assign(:show_note_modal, false)
         |> assign(:note_form, %{"note_text" => "", "note_type" => "general"})
         |> put_toast(:success, "Note added successfully")}

      {:error, _changeset} ->
        {:noreply, put_toast(socket, :error, "Failed to add note")}
    end
  end

  @impl true
  def handle_event("delete_note", %{"id" => note_id}, socket) do
    case Integer.parse(note_id) do
      {parsed_id, ""} ->
        case Polymarket.delete_investigation_note(parsed_id) do
          {:ok, _} ->
            notes = Polymarket.get_investigation_notes(socket.assigns.address)
            {:noreply,
             socket
             |> assign(:investigation_notes, notes)
             |> put_toast(:success, "Note deleted")}

          {:error, _reason} ->
            {:noreply, put_toast(socket, :error, "Failed to delete note")}
        end

      _ ->
        {:noreply, put_toast(socket, :error, "Invalid note ID")}
    end
  end

  @impl true
  def handle_event("export_csv", _params, socket) do
    address = socket.assigns.address
    trades = socket.assigns.trades
    summary = socket.assigns.summary

    csv_content = generate_csv(address, summary, trades)
    filename = "wallet_#{String.slice(address, 0, 8)}_#{Date.utc_today()}.csv"

    {:noreply,
     socket
     |> push_event("download", %{content: csv_content, filename: filename, content_type: "text/csv"})}
  end

  # CSV Generation
  defp generate_csv(address, summary, trades) do
    header = "Wallet Export Report\n"
    header = header <> "Address,#{address}\n"
    header = header <> "Total Trades,#{summary.total_trades}\n"
    header = header <> "Total Volume,#{summary.total_volume}\n"
    header = header <> "Win Rate,#{if summary.win_rate, do: Float.round(summary.win_rate * 100, 1), else: "N/A"}%\n"
    header = header <> "Avg Score,#{format_score(summary.avg_score)}\n\n"

    trades_header = "Trade History\n"
    trades_header = trades_header <> "Timestamp,Market,Side,Outcome,Size (USDC),Price,Result,Score\n"

    trades_data = Enum.map(trades, fn trade ->
      timestamp = if trade.trade_timestamp, do: DateTime.to_iso8601(trade.trade_timestamp), else: ""
      # Properly escape double quotes by doubling them (CSV standard)
      market = (trade.market_question || "Unknown") |> String.replace("\"", "\"\"")
      result = case trade.was_correct do
        true -> "Won"
        false -> "Lost"
        nil -> "Pending"
      end
      score = format_score(trade.anomaly_score)

      "#{timestamp},\"#{market}\",#{trade.side},#{trade.outcome},#{trade.usdc_size || 0},#{trade.price || 0},#{result},#{score}"
    end)

    header <> trades_header <> Enum.join(trades_data, "\n")
  end

  # Template helpers

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

  def format_zscore(nil), do: "N/A"
  def format_zscore(z) when is_float(z), do: "#{Float.round(z, 1)}σ"
  def format_zscore(z), do: "#{z}σ"

  def format_price(nil), do: "N/A"
  def format_price(price) when is_float(price), do: Float.round(price, 2) |> to_string()
  def format_price(%Decimal{} = d), do: Decimal.round(d, 2) |> Decimal.to_string()
  def format_price(n), do: "#{n}"

  def format_wallet(nil), do: "Unknown"
  def format_wallet(address) when byte_size(address) > 10 do
    "#{String.slice(address, 0, 6)}...#{String.slice(address, -4, 4)}"
  end
  def format_wallet(address), do: address

  def format_percent(nil), do: "N/A"
  def format_percent(rate) when is_float(rate), do: "#{Float.round(rate * 100, 0)}%"
  def format_percent(rate), do: "#{rate}%"

  def note_type_color("evidence"), do: :amber
  def note_type_color("action"), do: :green
  def note_type_color("dismissal"), do: :red
  def note_type_color(_), do: :zinc

  def note_type_icon("evidence"), do: "📋"
  def note_type_icon("action"), do: "✅"
  def note_type_icon("dismissal"), do: "❌"
  def note_type_icon(_), do: "📝"

  def score_tier_color(nil), do: :zinc
  def score_tier_color(%Decimal{} = d), do: score_tier_color(Decimal.to_float(d))
  def score_tier_color(score) when score >= 0.9, do: :red
  def score_tier_color(score) when score >= 0.7, do: :amber
  def score_tier_color(score) when score >= 0.5, do: :yellow
  def score_tier_color(score) when score >= 0.3, do: :blue
  def score_tier_color(_), do: :green

  def zscore_color(nil), do: "bg-zinc-500"
  def zscore_color(z) when z >= 3.0, do: "bg-red-500"
  def zscore_color(z) when z >= 2.0, do: "bg-orange-500"
  def zscore_color(z) when z >= 1.5, do: "bg-yellow-500"
  def zscore_color(_), do: "bg-green-500"

  def zscore_width(nil), do: "0%"
  def zscore_width(z) when is_float(z), do: "#{min(z / 5.0 * 100, 100)}%"
  def zscore_width(_), do: "0%"

  def status_color(:confirmed_insider), do: :red
  def status_color(:under_investigation), do: :amber
  def status_color(:candidate), do: :zinc
  def status_color(_), do: :zinc

  def status_label(:confirmed_insider), do: "Confirmed Insider"
  def status_label(:under_investigation), do: "Under Investigation"
  def status_label(:candidate), do: "Candidate"
  def status_label(_), do: "Unknown"

  def trade_result_icon(nil), do: "⏳"
  def trade_result_icon(true), do: "✅"
  def trade_result_icon(false), do: "❌"

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

  def risk_indicators(summary) do
    indicators = []

    indicators = if summary.wallet_age_days && summary.wallet_age_days <= 7 do
      [{:critical, "New Wallet (#{summary.wallet_age_days}d)"} | indicators]
    else
      indicators
    end

    indicators = if summary.win_rate && summary.win_rate >= 0.8 do
      [{:critical, "High Win Rate (#{Float.round(summary.win_rate * 100, 0)}%)"} | indicators]
    else
      indicators
    end

    indicators = if summary.critical_trades > 0 do
      [{:critical, "#{summary.critical_trades} Critical Trades"} | indicators]
    else
      indicators
    end

    indicators = if summary.avg_score && summary.avg_score >= 0.7 do
      [{:warning, "High Avg Score (#{Float.round(summary.avg_score, 2)})"} | indicators]
    else
      indicators
    end

    indicators = if summary.total_volume >= 50_000 do
      [{:warning, "Large Volume ($#{Float.round(summary.total_volume / 1000, 0)}K)"} | indicators]
    else
      indicators
    end

    Enum.reverse(indicators)
  end
end
