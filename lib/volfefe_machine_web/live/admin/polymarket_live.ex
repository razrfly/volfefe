defmodule VolfefeMachineWeb.Admin.PolymarketLive do
  @moduledoc """
  LiveView dashboard for Polymarket Insider Detection System.

  Provides real-time monitoring of:
  - System overview and stats
  - Alerts with severity badges
  - Investigation candidates queue
  - Pattern performance metrics
  """

  use VolfefeMachineWeb, :live_view

  import LiveToast
  alias VolfefeMachine.Polymarket
  alias VolfefeMachine.Polymarket.FormatHelpers

  @impl true
  def mount(_params, _session, socket) do
    if connected?(socket) do
      # Update stats every 10 seconds
      :timer.send_interval(10_000, self(), :refresh_data)
    end

    {:ok,
     socket
     |> assign(:page_title, "Polymarket Insider Detection")
     |> assign(:active_tab, :overview)
     |> load_data()}
  end

  @impl true
  def handle_params(params, _url, socket) do
    tab = case params["tab"] do
      "alerts" -> :alerts
      "candidates" -> :candidates
      "patterns" -> :patterns
      "discovery" -> :discovery
      _ -> :overview
    end

    {:noreply, assign(socket, :active_tab, tab)}
  end

  @impl true
  def handle_event("switch_tab", %{"tab" => tab}, socket) do
    {:noreply, push_patch(socket, to: ~p"/admin/polymarket?tab=#{tab}")}
  end

  @impl true
  def handle_event("acknowledge_alert", %{"id" => id}, socket) do
    case Polymarket.get_alert(String.to_integer(id)) do
      nil ->
        {:noreply, put_toast(socket, :error, "Alert not found")}

      alert ->
        case Polymarket.acknowledge_alert(alert, "admin") do
          {:ok, _alert} ->
            {:noreply,
             socket
             |> put_toast(:success, "Alert acknowledged")
             |> load_data()}

          {:error, _} ->
            {:noreply, put_toast(socket, :error, "Failed to acknowledge alert")}
        end
    end
  end

  @impl true
  def handle_event("investigate_alert", %{"id" => id}, socket) do
    case Polymarket.get_alert(String.to_integer(id)) do
      nil ->
        {:noreply, put_toast(socket, :error, "Alert not found")}

      alert ->
        case Polymarket.investigate_alert(alert, "admin") do
          {:ok, _alert} ->
            {:noreply,
             socket
             |> put_toast(:success, "Alert marked for investigation")
             |> load_data()}

          {:error, _} ->
            {:noreply, put_toast(socket, :error, "Failed to update alert")}
        end
    end
  end

  @impl true
  def handle_event("dismiss_alert", %{"id" => id}, socket) do
    case Polymarket.get_alert(String.to_integer(id)) do
      nil ->
        {:noreply, put_toast(socket, :error, "Alert not found")}

      alert ->
        case Polymarket.dismiss_alert(alert, "Dismissed from dashboard") do
          {:ok, _alert} ->
            {:noreply,
             socket
             |> put_toast(:success, "Alert dismissed")
             |> load_data()}

          {:error, _} ->
            {:noreply, put_toast(socket, :error, "Failed to dismiss alert")}
        end
    end
  end

  @impl true
  def handle_event("start_candidate_investigation", %{"id" => id}, socket) do
    case Polymarket.get_investigation_candidate(String.to_integer(id)) do
      nil ->
        {:noreply, put_toast(socket, :error, "Candidate not found")}

      candidate ->
        case Polymarket.start_investigation(candidate, "admin") do
          {:ok, _candidate} ->
            {:noreply,
             socket
             |> put_toast(:success, "Investigation started")
             |> load_data()}

          {:error, _} ->
            {:noreply, put_toast(socket, :error, "Failed to start investigation")}
        end
    end
  end

  @impl true
  def handle_event("dismiss_candidate", %{"id" => id}, socket) do
    case Polymarket.get_investigation_candidate(String.to_integer(id)) do
      nil ->
        {:noreply, put_toast(socket, :error, "Candidate not found")}

      candidate ->
        case Polymarket.dismiss_candidate(candidate, "Dismissed from dashboard", "admin") do
          {:ok, _candidate} ->
            {:noreply,
             socket
             |> put_toast(:success, "Candidate dismissed")
             |> load_data()}

          {:error, _} ->
            {:noreply, put_toast(socket, :error, "Failed to dismiss candidate")}
        end
    end
  end

  @impl true
  def handle_event("run_discovery", _params, socket) do
    case Polymarket.quick_discovery(limit: 20, min_score: 0.5) do
      {:ok, %{candidates: count}} ->
        {:noreply,
         socket
         |> put_toast(:success, "Discovery complete: #{count} new candidates found")
         |> load_data()}

      {:error, reason} ->
        {:noreply, put_toast(socket, :error, "Discovery failed: #{inspect(reason)}")}
    end
  end

  @impl true
  def handle_event("run_discovery_custom", params, socket) do
    with {:ok, limit} <- parse_integer(params["limit"], 50),
         {:ok, anomaly_threshold} <- parse_decimal(params["anomaly_threshold"], "0.5"),
         {:ok, probability_threshold} <- parse_decimal(params["probability_threshold"], "0.4") do
      opts = [
        limit: limit,
        anomaly_threshold: anomaly_threshold,
        probability_threshold: probability_threshold,
        notes: "Custom discovery from dashboard"
      ]

      case Polymarket.quick_discovery(opts) do
        {:ok, %{candidates: count}} ->
          {:noreply,
           socket
           |> put_toast(:success, "Discovery complete: #{count} new candidates found")
           |> load_data()}

        {:error, reason} ->
          {:noreply, put_toast(socket, :error, "Discovery failed: #{inspect(reason)}")}
      end
    else
      {:error, field} ->
        {:noreply, put_toast(socket, :error, "Invalid #{field} value")}
    end
  end

  @impl true
  def handle_event("export_candidates_csv", _params, socket) do
    candidates = socket.assigns.candidates

    csv_data = generate_candidates_csv(candidates)

    {:noreply,
     socket
     |> push_event("download", %{
       filename: "polymarket_candidates_#{Date.utc_today()}.csv",
       content: csv_data,
       content_type: "text/csv"
     })}
  end

  @impl true
  def handle_info(:refresh_data, socket) do
    {:noreply, load_data(socket)}
  end

  # Private functions

  defp parse_integer(nil, default), do: {:ok, default}
  defp parse_integer("", default), do: {:ok, default}
  defp parse_integer(str, _default) when is_binary(str) do
    case Integer.parse(str) do
      {n, ""} -> {:ok, n}
      _ -> {:error, "limit"}
    end
  end

  defp parse_decimal(nil, default), do: {:ok, Decimal.new(default)}
  defp parse_decimal("", default), do: {:ok, Decimal.new(default)}
  defp parse_decimal(str, _default) when is_binary(str) do
    case Decimal.parse(str) do
      {d, ""} -> {:ok, d}
      {d, _remainder} -> {:ok, d}
      :error -> {:error, "threshold"}
    end
  end

  defp load_data(socket) do
    dashboard = Polymarket.monitoring_dashboard()
    investigation = Polymarket.investigation_dashboard()
    pattern_statistics = Polymarket.pattern_stats()

    socket
    |> assign(:dashboard, dashboard)
    |> assign(:investigation, investigation)
    |> assign(:pattern_stats, pattern_statistics)
    |> assign(:alerts, Polymarket.list_alerts(limit: 50))
    |> assign(:candidates, Polymarket.list_investigation_candidates(limit: 50))
    |> assign(:patterns, Polymarket.list_insider_patterns(include_stats: true))
    |> assign(:discovery_batches, Polymarket.list_discovery_batches(limit: 20))
  end

  defp generate_candidates_csv(candidates) do
    headers = ["ID", "Rank", "Wallet", "Priority", "Status", "Insider Probability", "Anomaly Score", "Market", "Discovered At"]

    rows = Enum.map(candidates, fn c ->
      [
        c.id,
        c.discovery_rank,
        c.wallet_address,
        c.priority,
        c.status,
        format_decimal(c.insider_probability),
        format_decimal(c.anomaly_score),
        c.market_question || "N/A",
        format_datetime(c.discovered_at)
      ]
    end)

    [headers | rows]
    |> Enum.map(&FormatHelpers.csv_row/1)
    |> Enum.join("\n")
  end

  defp format_decimal(nil), do: "N/A"
  defp format_decimal(%Decimal{} = d), do: Decimal.to_string(d)
  defp format_decimal(n), do: "#{n}"

  # Helper functions for templates

  def severity_badge_class("critical"), do: "bg-red-100 text-red-800 ring-red-600/20"
  def severity_badge_class("high"), do: "bg-orange-100 text-orange-800 ring-orange-600/20"
  def severity_badge_class("medium"), do: "bg-yellow-100 text-yellow-800 ring-yellow-600/20"
  def severity_badge_class("low"), do: "bg-green-100 text-green-800 ring-green-600/20"
  def severity_badge_class(_), do: "bg-gray-100 text-gray-800 ring-gray-600/20"

  def status_badge_class("new"), do: "bg-blue-100 text-blue-800"
  def status_badge_class("acknowledged"), do: "bg-purple-100 text-purple-800"
  def status_badge_class("investigating"), do: "bg-yellow-100 text-yellow-800"
  def status_badge_class("resolved"), do: "bg-green-100 text-green-800"
  def status_badge_class("dismissed"), do: "bg-gray-100 text-gray-800"
  def status_badge_class("undiscovered"), do: "bg-blue-100 text-blue-800"
  def status_badge_class("pending_review"), do: "bg-purple-100 text-purple-800"
  def status_badge_class("confirmed_insider"), do: "bg-red-100 text-red-800"
  def status_badge_class("cleared"), do: "bg-green-100 text-green-800"
  def status_badge_class(_), do: "bg-gray-100 text-gray-800"

  def severity_icon("critical"), do: "🚨"
  def severity_icon("high"), do: "⚠️"
  def severity_icon("medium"), do: "📊"
  def severity_icon("low"), do: "ℹ️"
  def severity_icon(_), do: "❓"

  def format_probability(nil), do: "N/A"
  def format_probability(%Decimal{} = d), do: "#{Decimal.round(Decimal.mult(d, 100), 1)}%"
  def format_probability(f) when is_float(f), do: "#{Float.round(f * 100, 1)}%"
  def format_probability(n), do: "#{n}%"

  def format_datetime(nil), do: "N/A"
  def format_datetime(%DateTime{} = dt) do
    Calendar.strftime(dt, "%Y-%m-%d %H:%M")
  end
  def format_datetime(%NaiveDateTime{} = dt) do
    Calendar.strftime(dt, "%Y-%m-%d %H:%M")
  end

  def relative_time(nil), do: "N/A"
  def relative_time(%DateTime{} = dt) do
    seconds = DateTime.diff(DateTime.utc_now(), dt)
    format_relative_seconds(seconds)
  end
  def relative_time(%NaiveDateTime{} = dt) do
    {:ok, datetime} = DateTime.from_naive(dt, "Etc/UTC")
    relative_time(datetime)
  end

  defp format_relative_seconds(seconds) when seconds < 0, do: "just now"
  defp format_relative_seconds(seconds) when seconds < 60, do: "#{seconds}s ago"
  defp format_relative_seconds(seconds) when seconds < 3600, do: "#{div(seconds, 60)}m ago"
  defp format_relative_seconds(seconds) when seconds < 86400, do: "#{div(seconds, 3600)}h ago"
  defp format_relative_seconds(seconds), do: "#{div(seconds, 86400)}d ago"

  def truncate(nil, _), do: ""
  def truncate(str, max_length) when is_binary(str) do
    if String.length(str) > max_length do
      String.slice(str, 0, max_length) <> "..."
    else
      str
    end
  end

  def format_wallet(nil), do: "Unknown"
  def format_wallet(address) when byte_size(address) > 10 do
    "#{String.slice(address, 0, 6)}...#{String.slice(address, -4, 4)}"
  end
  def format_wallet(address), do: address
end
