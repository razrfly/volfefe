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
  alias VolfefeMachine.Polymarket.DiversityMonitor

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
      "coverage" -> :coverage
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
    coverage_health = DiversityMonitor.health_summary()

    socket
    |> assign(:dashboard, dashboard)
    |> assign(:investigation, investigation)
    |> assign(:pattern_stats, pattern_statistics)
    |> assign(:coverage_health, coverage_health)
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

  # Helper functions for templates - Catalyst badge color atoms

  def severity_to_color("critical"), do: :red
  def severity_to_color("high"), do: :amber
  def severity_to_color("medium"), do: :zinc
  def severity_to_color("low"), do: :zinc
  def severity_to_color(_), do: :zinc

  def status_to_color("new"), do: :zinc
  def status_to_color("acknowledged"), do: :zinc
  def status_to_color("investigating"), do: :amber
  def status_to_color("resolved"), do: :green
  def status_to_color("dismissed"), do: :zinc
  def status_to_color("undiscovered"), do: :zinc
  def status_to_color("pending_review"), do: :amber
  def status_to_color("confirmed_insider"), do: :red
  def status_to_color("cleared"), do: :green
  def status_to_color(_), do: :zinc

  def priority_to_color("high"), do: :red
  def priority_to_color("critical"), do: :red
  def priority_to_color("medium"), do: :amber
  def priority_to_color(_), do: :zinc

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

  # Coverage helpers - Catalyst styled

  def health_score_class(score) when score >= 80, do: "text-zinc-950 dark:text-white"
  def health_score_class(score) when score >= 50, do: "text-amber-700 dark:text-amber-400"
  def health_score_class(_score), do: "text-red-700 dark:text-red-400"

  def coverage_health_ring(score) when score >= 80, do: "bg-zinc-50 ring-zinc-200 dark:bg-zinc-800/50 dark:ring-zinc-700"
  def coverage_health_ring(score) when score >= 50, do: "bg-amber-50 ring-amber-200 dark:bg-amber-900/20 dark:ring-amber-700"
  def coverage_health_ring(_score), do: "bg-red-50 ring-red-200 dark:bg-red-900/20 dark:ring-red-700"

  def health_score_badge_color(score) when score >= 80, do: :green
  def health_score_badge_color(score) when score >= 50, do: :amber
  def health_score_badge_color(_score), do: :red

  def health_score_label(score) when score >= 80, do: "Good"
  def health_score_label(score) when score >= 50, do: "Warning"
  def health_score_label(_score), do: "Poor"

  def format_number(n) when is_integer(n) do
    n
    |> Integer.to_string()
    |> String.reverse()
    |> String.replace(~r/(\d{3})(?=\d)/, "\\1,")
    |> String.reverse()
  end
  def format_number(n), do: "#{n}"
end
