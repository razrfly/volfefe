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
  alias VolfefeMachine.Polymarket.DataSourceHealth
  alias VolfefeMachine.Polymarket.Validation

  @impl true
  def mount(_params, _session, socket) do
    if connected?(socket) do
      # Update stats every 10 seconds
      :timer.send_interval(10_000, self(), :refresh_data)

      # Subscribe to data source failover events
      Phoenix.PubSub.subscribe(VolfefeMachine.PubSub, "data_source:failover")

      # Subscribe to activity feed
      Phoenix.PubSub.subscribe(VolfefeMachine.PubSub, "dashboard:activity")
    end

    {:ok,
     socket
     |> assign(:page_title, "Polymarket Insider Detection")
     |> assign(:active_tab, :overview)
     |> assign(:date_range, "7d")
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
      "analytics" -> :analytics
      "insiders" -> :insiders
      "pilot" -> :pilot
      _ -> :overview
    end

    {:noreply, assign(socket, :active_tab, tab)}
  end

  @impl true
  def handle_event("switch_tab", %{"tab" => tab}, socket) do
    {:noreply, push_patch(socket, to: ~p"/admin/polymarket?tab=#{tab}")}
  end

  @impl true
  def handle_event("change_date_range", %{"range" => range}, socket) do
    {:noreply,
     socket
     |> assign(:date_range, range)
     |> load_data()}
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
  def handle_event("promote_alert", %{"id" => id}, socket) do
    case Polymarket.get_alert(String.to_integer(id)) do
      nil ->
        {:noreply, put_toast(socket, :error, "Alert not found")}

      alert ->
        case Polymarket.promote_alert_to_candidate(alert) do
          {:ok, candidate} ->
            {:noreply,
             socket
             |> put_toast(:success, "Alert promoted to candidate: #{String.slice(candidate.wallet_address, 0..9)}...")
             |> load_data()}

          {:error, :candidate_exists} ->
            {:noreply, put_toast(socket, :info, "Candidate already exists for this wallet")}

          {:error, _changeset} ->
            {:noreply, put_toast(socket, :error, "Failed to promote alert")}
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
  def handle_event("refresh_data_sources", _params, socket) do
    case DataSourceHealth.check_now() do
      {:ok, summary} ->
        {:noreply,
         socket
         |> assign(:data_source_health, summary)
         |> put_toast(:success, "Data source health refreshed")}

      {:error, _reason} ->
        {:noreply, put_toast(socket, :error, "Failed to refresh data source health")}
    end
  end

  @impl true
  def handle_event("recalculate_baselines", _params, socket) do
    try do
      {:ok, %{updated: updated}} = Polymarket.calculate_insider_baselines()
      {:noreply,
       socket
       |> put_toast(:success, "Recalculated #{updated} baselines")
       |> load_data()}
    rescue
      e ->
        {:noreply, put_toast(socket, :error, "Failed to recalculate baselines: #{Exception.message(e)}")}
    end
  end

  @impl true
  def handle_event("validate_patterns", _params, socket) do
    try do
      {:ok, result} = Polymarket.validate_patterns()
      {:noreply,
       socket
       |> put_toast(:success, "Validated #{result.validated} patterns")
       |> load_data()}
    rescue
      e ->
        {:noreply, put_toast(socket, :error, "Failed to validate patterns: #{Exception.message(e)}")}
    end
  end

  @impl true
  def handle_event("rescore_trades", _params, socket) do
    try do
      {:ok, %{total: total, scored: scored}} = Polymarket.rescore_all_trades(batch_size: 1000)
      {:noreply,
       socket
       |> put_toast(:success, "Rescored #{scored}/#{total} trades")
       |> load_data()}
    rescue
      e ->
        {:noreply, put_toast(socket, :error, "Failed to rescore trades: #{Exception.message(e)}")}
    end
  end

  @impl true
  def handle_event("run_feedback_iteration", _params, socket) do
    try do
      {:ok, result} = Polymarket.run_feedback_loop()
      {:noreply,
       socket
       |> put_toast(:success, "Feedback iteration #{result.iteration} complete")
       |> load_data()}
    rescue
      e ->
        {:noreply, put_toast(socket, :error, "Failed to run feedback loop: #{Exception.message(e)}")}
    end
  end

  # Note: Real-time monitoring is now handled by Oban workers:
  # - TradeIngestionWorker (every 2 min)
  # - TradeScoringWorker (every 5 min)
  # - AlertingWorker (every 10 min)
  # These event handlers are kept for backwards compatibility but now show info messages.

  @impl true
  def handle_event("enable_monitor", _params, socket) do
    {:noreply, put_toast(socket, :info, "Monitoring is automatic via Oban workers")}
  end

  @impl true
  def handle_event("disable_monitor", _params, socket) do
    {:noreply, put_toast(socket, :info, "Monitoring is automatic via Oban workers")}
  end

  @impl true
  def handle_event("poll_now", _params, socket) do
    {:noreply, put_toast(socket, :info, "Use 'mix polymarket.ingest' for manual ingestion")}
  end

  @impl true
  def handle_event("run_pilot_validation", _params, socket) do
    case Validation.validate_detection() do
      {:ok, results} ->
        {:noreply,
         socket
         |> assign(:pilot_validation, results)
         |> put_toast(:success, "Validation complete: #{results.detection_rate * 100}% detection rate")}
    end
  end

  @impl true
  def handle_event("run_pilot_metrics", _params, socket) do
    case Validation.calculate_metrics() do
      {:ok, metrics} ->
        {:noreply,
         socket
         |> assign(:pilot_metrics, metrics)
         |> put_toast(:success, "Metrics calculated: F1=#{Float.round(metrics.f1_score * 100, 1)}%")}
    end
  end

  @impl true
  def handle_event("run_pilot_batch", params, socket) do
    limit = parse_batch_limit(params["limit"])

    case Validation.run_batch_pilot(limit: limit) do
      {:ok, results} ->
        {:noreply,
         socket
         |> assign(:pilot_batch_results, results)
         |> put_toast(:success, "Batch complete: #{results.markets_processed} markets, #{results.candidates_generated} candidates")}
    end
  end

  @impl true
  def handle_event("run_pilot_optimize", _params, socket) do
    case Validation.optimize_thresholds() do
      {:ok, []} ->
        {:noreply,
         socket
         |> assign(:pilot_optimization, [])
         |> put_toast(:info, "No optimization results - insufficient data for threshold tuning")}

      {:ok, results} ->
        best = List.first(results)
        {:noreply,
         socket
         |> assign(:pilot_optimization, results)
         |> put_toast(:success, "Optimization complete: best F1=#{Float.round(best.f1_score * 100, 1)}% at anomaly=#{best.anomaly_threshold}, prob=#{best.probability_threshold}")}
    end
  end

  @impl true
  def handle_event("analyze_false_negatives", _params, socket) do
    case Validation.analyze_false_negatives() do
      {:ok, analysis} ->
        {:noreply,
         socket
         |> assign(:pilot_fn_analysis, analysis)
         |> put_toast(:info, "Found #{analysis.total_missed} false negatives")}
    end
  end

  @impl true
  def handle_event("unwatch_market", %{"market-id" => market_id}, socket) do
    market_id = String.to_integer(market_id)

    case Polymarket.unwatch_market(market_id) do
      {:ok, _} ->
        {:noreply,
         socket
         |> put_toast(:success, "Market unwatched")
         |> load_data()}

      {:error, :not_found} ->
        {:noreply, put_toast(socket, :error, "Market not found in watch list")}
    end
  end

  defp parse_batch_limit(nil), do: 10
  defp parse_batch_limit(""), do: 10
  defp parse_batch_limit(str) when is_binary(str) do
    case Integer.parse(str) do
      {n, ""} -> min(max(n, 1), 50)
      _ -> 10
    end
  end

  @impl true
  def handle_info(:refresh_data, socket) do
    {:noreply, load_data(socket)}
  end

  @impl true
  def handle_info({:activity, event_type, data}, socket) do
    # Add new activity to the feed
    activity_item = %{
      type: to_string(event_type),
      timestamp: DateTime.utc_now(),
      data: data
    }

    current_activity = socket.assigns[:activity_feed] || []
    updated_feed = [activity_item | current_activity] |> Enum.take(50)

    {:noreply, assign(socket, :activity_feed, updated_feed)}
  end

  @impl true
  def handle_info({:failover, %{from: from, to: to, reason: reason}}, socket) do
    from_name = if from == :api, do: "API", else: "Subgraph"
    to_name = if to == :subgraph, do: "Subgraph", else: "API"
    reason_str = inspect(reason)

    {:noreply,
     socket
     |> put_toast(:warning, "Data source failover: #{from_name} → #{to_name} (#{reason_str})")
     |> load_data()}
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
    date_range = socket.assigns[:date_range] || "7d"

    dashboard = Polymarket.monitoring_dashboard()
    investigation = Polymarket.investigation_dashboard()
    pattern_statistics = Polymarket.pattern_stats()
    coverage_health = DiversityMonitor.health_summary()
    data_source_health = DataSourceHealth.health_summary()
    feedback_stats = Polymarket.feedback_loop_stats()
    confirmed_insiders = Polymarket.list_confirmed_insiders(limit: 50)
    base_insider_stats = Polymarket.confirmed_insider_stats()
    trained_count = Enum.count(confirmed_insiders, & &1.used_for_training)
    insider_stats = Map.put(base_insider_stats, :trained, trained_count)
    pilot_progress = Validation.pilot_progress()

    # Load date-filtered dashboard stats for Phase 3 MVP
    dashboard_stats = Polymarket.dashboard_stats(range: date_range)

    # Load watched markets
    watched_markets = Polymarket.list_watched_markets(range: date_range, limit: 20)

    socket
    |> assign(:dashboard, dashboard)
    |> assign(:investigation, investigation)
    |> assign(:pattern_stats, pattern_statistics)
    |> assign(:coverage_health, coverage_health)
    |> assign(:data_source_health, data_source_health)
    |> assign(:feedback_stats, feedback_stats)
    |> assign(:confirmed_insiders, confirmed_insiders)
    |> assign(:insider_stats, insider_stats)
    |> assign(:alerts, Polymarket.list_alerts(limit: 50))
    |> assign(:candidates, Polymarket.list_investigation_candidates(limit: 50))
    |> assign(:patterns, Polymarket.list_insider_patterns(include_stats: true))
    |> assign(:discovery_batches, Polymarket.list_discovery_batches(limit: 20))
    |> assign(:pilot_progress, pilot_progress)
    |> assign(:dashboard_stats, dashboard_stats)
    |> assign(:watched_markets, watched_markets)
    |> assign_new(:activity_feed, fn -> dashboard_stats.recent_activity end)
    |> assign_new(:pilot_validation, fn -> nil end)
    |> assign_new(:pilot_metrics, fn -> nil end)
    |> assign_new(:pilot_batch_results, fn -> nil end)
    |> assign_new(:pilot_optimization, fn -> nil end)
    |> assign_new(:pilot_fn_analysis, fn -> nil end)
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

  # Score tier helpers for activity feed
  def score_tier_color(score) when is_nil(score), do: :zinc
  def score_tier_color(%Decimal{} = score), do: score_tier_color(Decimal.to_float(score))
  def score_tier_color(score) when score >= 0.9, do: :red
  def score_tier_color(score) when score >= 0.7, do: :amber
  def score_tier_color(score) when score >= 0.5, do: :yellow
  def score_tier_color(score) when score >= 0.3, do: :blue
  def score_tier_color(_), do: :green

  def format_score(nil), do: "N/A"
  def format_score(%Decimal{} = d), do: Decimal.round(d, 2) |> Decimal.to_string()
  def format_score(f) when is_float(f), do: Float.round(f, 2) |> to_string()
  def format_score(n), do: "#{n}"

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

  # Data source health helpers

  def data_source_status_color(%{healthy: true}), do: :green
  def data_source_status_color(%{healthy: false}), do: :red
  def data_source_status_color(_), do: :zinc

  def data_source_status_label(%{healthy: true}), do: "healthy"
  def data_source_status_label(%{healthy: false}), do: "unhealthy"
  def data_source_status_label(_), do: "unknown"

  def recommended_source_icon(:subgraph), do: "🔗"
  def recommended_source_icon(:api), do: "🌐"
  def recommended_source_icon(_), do: "⚡"

  def format_success_rate(rate) when is_number(rate) do
    "#{Float.round(rate * 100, 1)}%"
  end
  def format_success_rate(_), do: "N/A"

  def format_uptime(seconds) when seconds < 60, do: "#{seconds}s"
  def format_uptime(seconds) when seconds < 3600 do
    "#{div(seconds, 60)}m #{rem(seconds, 60)}s"
  end
  def format_uptime(seconds) do
    hours = div(seconds, 3600)
    mins = div(rem(seconds, 3600), 60)
    "#{hours}h #{mins}m"
  end

  # Insider helpers

  def confidence_to_color("high"), do: :green
  def confidence_to_color("medium"), do: :amber
  def confidence_to_color("low"), do: :zinc
  def confidence_to_color(_), do: :zinc

  def format_source("resolution_matched"), do: "Resolution Matched"
  def format_source("manual_review"), do: "Manual Review"
  def format_source("pattern_confirmed"), do: "Pattern Confirmed"
  def format_source("reference_case"), do: "Reference Case"
  def format_source(source) when is_binary(source), do: String.replace(source, "_", " ") |> String.capitalize()
  def format_source(_), do: "Unknown"

  def format_profit(nil), do: "N/A"
  def format_profit(%Decimal{} = d) do
    value = Decimal.to_float(d)
    cond do
      value >= 1000 -> "$#{Float.round(value / 1000, 1)}K"
      value >= 0 -> "$#{Float.round(value, 2)}"
      true -> "-$#{Float.round(abs(value), 2)}"
    end
  end
  def format_profit(value) when is_number(value) do
    cond do
      value >= 1000 -> "$#{Float.round(value / 1000, 1)}K"
      value >= 0 -> "$#{Float.round(value, 2)}"
      true -> "-$#{Float.round(abs(value), 2)}"
    end
  end
  def format_profit(_), do: "N/A"

  # Pilot status helpers

  def pilot_status_color(:ready_for_production), do: :green
  def pilot_status_color(:pilot_in_progress), do: :amber
  def pilot_status_color(:metrics_below_target), do: :amber
  def pilot_status_color(:detection_poor), do: :red
  def pilot_status_color(:need_more_insiders), do: :zinc
  def pilot_status_color(_), do: :zinc

  def pilot_status_label(:ready_for_production), do: "Ready for Production"
  def pilot_status_label(:pilot_in_progress), do: "Pilot In Progress"
  def pilot_status_label(:metrics_below_target), do: "Metrics Below Target"
  def pilot_status_label(:detection_poor), do: "Poor Detection"
  def pilot_status_label(:need_more_insiders), do: "Need More Data"
  def pilot_status_label(_), do: "Unknown"

  def format_percentage(nil), do: "N/A"
  def format_percentage(f) when is_float(f), do: "#{Float.round(f * 100, 1)}%"
  def format_percentage(n), do: "#{n}%"

  def format_rate(nil), do: "N/A"
  def format_rate(0), do: "0%"
  def format_rate(f) when is_float(f) and f == 0.0, do: "0%"
  def format_rate(f) when is_float(f), do: "#{Float.round(f * 100, 1)}%"
  def format_rate(n), do: "#{n * 100}%"

  def fn_reason_color("no_trade_data"), do: :zinc
  def fn_reason_color("trade_not_scored"), do: :zinc
  def fn_reason_color("low_anomaly_score"), do: :amber
  def fn_reason_color("low_probability"), do: :amber
  def fn_reason_color(_), do: :zinc
end
