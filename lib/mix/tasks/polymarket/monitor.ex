defmodule Mix.Tasks.Polymarket.Monitor do
  @moduledoc """
  Control the real-time trade monitor for insider detection.

  The monitor polls for new trades, scores them against learned insider patterns,
  and generates alerts when suspicious activity is detected.

  ## Commands

      # Check monitor status
      mix polymarket.monitor

      # Enable monitoring
      mix polymarket.monitor --enable

      # Disable monitoring
      mix polymarket.monitor --disable

      # Trigger immediate poll cycle
      mix polymarket.monitor --poll

      # Adjust thresholds
      mix polymarket.monitor --anomaly 0.8 --probability 0.6

      # Watch mode - show live alerts
      mix polymarket.monitor --watch

  ## Options

      --enable          Enable real-time monitoring
      --disable         Disable real-time monitoring
      --poll            Trigger immediate poll cycle
      --anomaly FLOAT   Set anomaly score threshold (default: 0.7)
      --probability FLOAT  Set insider probability threshold (default: 0.5)
      --watch           Watch for new alerts (Ctrl+C to exit)
      --recent N        Show N recent alerts (default: 10)

  ## How It Works

      1. Polls database for unscored trades every 30 seconds
      2. Scores each trade using z-scores from learned insider baselines
      3. If anomaly_score >= threshold OR insider_probability >= threshold:
         - Generates alert with severity based on scores
         - Broadcasts via PubSub for LiveView updates
      4. Alerts visible in /admin/polymarket and via `mix polymarket.alerts`

  ## Integration with Insider Detection

      The monitor uses patterns learned from confirmed insiders (Phase 2):
      - Size baselines: Insiders trade ~17x larger than normal
      - Timing baselines: Insiders trade closer to resolution
      - Activity baselines: Insider wallet patterns

      To improve detection accuracy:
      1. Confirm more insiders: mix polymarket.confirm --id ID
      2. Run feedback loop: mix polymarket.feedback
      3. Patterns auto-update as more insiders are confirmed
  """

  use Mix.Task
  alias VolfefeMachine.Polymarket.TradeMonitor
  alias VolfefeMachine.Polymarket

  @shortdoc "Control real-time trade monitoring"

  @impl Mix.Task
  def run(args) do
    Mix.Task.run("app.start")

    {opts, _, _} = OptionParser.parse(args,
      switches: [
        enable: :boolean,
        disable: :boolean,
        poll: :boolean,
        anomaly: :float,
        probability: :float,
        watch: :boolean,
        recent: :integer
      ],
      aliases: [e: :enable, d: :disable, p: :poll, w: :watch, r: :recent]
    )

    cond do
      opts[:enable] ->
        enable_monitor()

      opts[:disable] ->
        disable_monitor()

      opts[:poll] ->
        trigger_poll()

      opts[:anomaly] || opts[:probability] ->
        update_thresholds(opts)

      opts[:watch] ->
        watch_alerts()

      opts[:recent] ->
        show_recent_alerts(opts[:recent])

      true ->
        show_status()
    end
  end

  # ============================================================================
  # Commands
  # ============================================================================

  defp show_status do
    status = TradeMonitor.status()

    print_header("TRADE MONITOR STATUS")

    enabled_icon = if status.enabled, do: "🟢", else: "🔴"
    Mix.shell().info("#{enabled_icon} Status: #{if status.enabled, do: "ENABLED", else: "DISABLED"}")
    Mix.shell().info("")

    Mix.shell().info("Configuration:")
    Mix.shell().info("  Poll Interval:     #{status.poll_interval}ms (#{div(status.poll_interval, 1000)}s)")
    Mix.shell().info("  Anomaly Threshold: #{status.thresholds.anomaly}")
    Mix.shell().info("  Probability Threshold: #{status.thresholds.probability}")
    Mix.shell().info("")

    Mix.shell().info("Statistics:")
    Mix.shell().info("  Last Poll:         #{format_time(status.stats.last_poll_at)}")
    Mix.shell().info("  Trades Processed:  #{status.stats.trades_processed}")
    Mix.shell().info("  Alerts Generated:  #{status.stats.alerts_generated}")
    Mix.shell().info("  Errors:            #{status.stats.errors}")

    # Show baseline health
    Mix.shell().info("")
    print_baseline_health()

    # Show recent alerts summary
    Mix.shell().info("")
    show_alert_summary()

    Mix.shell().info("")
    print_divider()
    Mix.shell().info("Commands:")
    Mix.shell().info("  mix polymarket.monitor --enable    # Start monitoring")
    Mix.shell().info("  mix polymarket.monitor --poll      # Trigger immediate poll")
    Mix.shell().info("  mix polymarket.monitor --watch     # Watch for alerts")
    Mix.shell().info("")
  end

  defp enable_monitor do
    case TradeMonitor.enable() do
      :ok ->
        Mix.shell().info("")
        Mix.shell().info("🟢 Trade Monitor ENABLED")
        Mix.shell().info("")
        Mix.shell().info("The monitor will now:")
        Mix.shell().info("  • Poll for new trades every 30 seconds")
        Mix.shell().info("  • Score trades using learned insider patterns")
        Mix.shell().info("  • Generate alerts for suspicious activity")
        Mix.shell().info("")
        Mix.shell().info("View alerts: mix polymarket.alerts")
        Mix.shell().info("Watch live:  mix polymarket.monitor --watch")
        Mix.shell().info("")

      error ->
        Mix.shell().error("Failed to enable monitor: #{inspect(error)}")
    end
  end

  defp disable_monitor do
    case TradeMonitor.disable() do
      :ok ->
        Mix.shell().info("")
        Mix.shell().info("🔴 Trade Monitor DISABLED")
        Mix.shell().info("")

      error ->
        Mix.shell().error("Failed to disable monitor: #{inspect(error)}")
    end
  end

  defp trigger_poll do
    Mix.shell().info("")
    Mix.shell().info("🔄 Triggering poll cycle...")

    TradeMonitor.poll_now()

    # Wait a moment for poll to complete
    Process.sleep(2000)

    status = TradeMonitor.status()
    Mix.shell().info("")
    Mix.shell().info("Poll complete:")
    Mix.shell().info("  Trades Processed: #{status.stats.trades_processed}")
    Mix.shell().info("  Alerts Generated: #{status.stats.alerts_generated}")
    Mix.shell().info("")
  end

  defp update_thresholds(opts) do
    threshold_opts = []
    threshold_opts = if opts[:anomaly], do: [{:anomaly, opts[:anomaly]} | threshold_opts], else: threshold_opts
    threshold_opts = if opts[:probability], do: [{:probability, opts[:probability]} | threshold_opts], else: threshold_opts

    case TradeMonitor.set_thresholds(threshold_opts) do
      :ok ->
        Mix.shell().info("")
        Mix.shell().info("✅ Thresholds updated:")
        if opts[:anomaly], do: Mix.shell().info("  Anomaly: #{opts[:anomaly]}")
        if opts[:probability], do: Mix.shell().info("  Probability: #{opts[:probability]}")
        Mix.shell().info("")

      error ->
        Mix.shell().error("Failed to update thresholds: #{inspect(error)}")
    end
  end

  defp watch_alerts do
    Mix.shell().info("")
    Mix.shell().info("👁️  Watching for new alerts (Ctrl+C to exit)")
    Mix.shell().info("")
    print_divider()

    # Subscribe to alerts channel
    Phoenix.PubSub.subscribe(VolfefeMachine.PubSub, "polymarket:alerts")

    # Show current status
    status = TradeMonitor.status()
    if not status.enabled do
      Mix.shell().info("⚠️  Monitor is currently DISABLED. Enable with --enable to see live alerts.")
      Mix.shell().info("")
    end

    # Enter watch loop
    watch_loop()
  end

  defp watch_loop do
    receive do
      {:alert, alert} ->
        print_live_alert(alert)
        watch_loop()

      {:new_alert, alert} ->
        print_live_alert(alert)
        watch_loop()

      _ ->
        watch_loop()
    after
      30_000 ->
        # Heartbeat every 30s
        Mix.shell().info("  [#{DateTime.utc_now() |> DateTime.to_time() |> Time.to_string()}] Watching...")
        watch_loop()
    end
  end

  defp print_live_alert(alert) do
    icon = severity_icon(alert.severity)
    time = DateTime.utc_now() |> DateTime.to_time() |> Time.to_string()

    Mix.shell().info("")
    Mix.shell().info("#{icon} [#{time}] NEW ALERT")
    Mix.shell().info("   Severity: #{alert.severity |> String.upcase()}")
    Mix.shell().info("   Wallet:   #{format_wallet(alert.wallet_address)}")
    Mix.shell().info("   Probability: #{format_probability(alert.insider_probability)}")
    Mix.shell().info("   Anomaly: #{format_decimal(alert.anomaly_score)}")
    if alert.market_question do
      Mix.shell().info("   Market: #{truncate(alert.market_question, 50)}")
    end
    Mix.shell().info("")
  end

  defp show_recent_alerts(limit) do
    alerts = TradeMonitor.recent_alerts(limit)

    if Enum.empty?(alerts) do
      Mix.shell().info("")
      Mix.shell().info("No alerts found.")
      Mix.shell().info("")
    else
      print_header("RECENT ALERTS (#{length(alerts)})")

      Enum.each(alerts, fn alert ->
        icon = severity_icon(alert.severity)
        wallet = format_wallet(alert.wallet_address)
        prob = format_probability(alert.insider_probability)

        Mix.shell().info("#{icon} ##{alert.id} [#{alert.severity |> String.upcase()}] #{wallet}")
        Mix.shell().info("   Probability: #{prob} | #{relative_time(alert.triggered_at)}")
        if alert.market_question do
          Mix.shell().info("   Market: #{truncate(alert.market_question, 50)}")
        end
        Mix.shell().info("")
      end)
    end
  end

  # ============================================================================
  # Helpers
  # ============================================================================

  defp print_baseline_health do
    stats = Polymarket.feedback_loop_stats()

    Mix.shell().info("Baseline Health:")

    if stats.baselines.total > 0 do
      Mix.shell().info("  Baselines:         #{stats.baselines.total}")
      Mix.shell().info("  With Insider Data: #{stats.baselines.with_insider_data}")
      Mix.shell().info("  Avg Separation:    #{Float.round(stats.baselines.avg_separation_score || 0.0, 2)}")
    else
      Mix.shell().info("  ⚠️  No baselines found. Run: mix polymarket.feedback")
    end

    Mix.shell().info("  Confirmed Insiders: #{stats.confirmed_insiders.total}")

    if stats.confirmed_insiders.untrained > 0 do
      Mix.shell().info("  ⚠️  #{stats.confirmed_insiders.untrained} untrained insider(s) - run: mix polymarket.feedback")
    end
  end

  defp show_alert_summary do
    alerts = Polymarket.list_alerts(limit: 100, status: "new")

    if length(alerts) > 0 do
      critical = Enum.count(alerts, & &1.severity == "critical")
      high = Enum.count(alerts, & &1.severity == "high")
      medium = Enum.count(alerts, & &1.severity == "medium")

      Mix.shell().info("Pending Alerts:")
      if critical > 0, do: Mix.shell().info("  🚨 Critical: #{critical}")
      if high > 0, do: Mix.shell().info("  ⚠️  High: #{high}")
      if medium > 0, do: Mix.shell().info("  📊 Medium: #{medium}")
      Mix.shell().info("")
      Mix.shell().info("View all: mix polymarket.alerts --status new")
    else
      Mix.shell().info("Pending Alerts: None")
    end
  end

  defp print_header(title) do
    Mix.shell().info("")
    Mix.shell().info(String.duplicate("═", 65))
    Mix.shell().info(title)
    Mix.shell().info(String.duplicate("═", 65))
    Mix.shell().info("")
  end

  defp print_divider do
    Mix.shell().info(String.duplicate("─", 65))
  end

  defp format_time(nil), do: "Never"
  defp format_time(%DateTime{} = dt), do: "#{relative_time(dt)} (#{DateTime.to_time(dt) |> Time.to_string()})"

  defp severity_icon("critical"), do: "🚨"
  defp severity_icon("high"), do: "⚠️"
  defp severity_icon("medium"), do: "📊"
  defp severity_icon("low"), do: "ℹ️"
  defp severity_icon(_), do: "❓"

  defp format_wallet(nil), do: "Unknown"
  defp format_wallet(address) when byte_size(address) > 10 do
    "#{String.slice(address, 0, 6)}...#{String.slice(address, -4, 4)}"
  end
  defp format_wallet(address), do: address

  defp format_probability(nil), do: "N/A"
  defp format_probability(%Decimal{} = d), do: "#{Decimal.round(Decimal.mult(d, 100), 1)}%"
  defp format_probability(f) when is_float(f), do: "#{Float.round(f * 100, 1)}%"
  defp format_probability(n), do: "#{n}%"

  defp format_decimal(nil), do: "N/A"
  defp format_decimal(%Decimal{} = d), do: Decimal.to_string(d)
  defp format_decimal(n), do: "#{n}"

  defp relative_time(nil), do: "N/A"
  defp relative_time(%DateTime{} = dt) do
    seconds = DateTime.diff(DateTime.utc_now(), dt)
    format_relative_seconds(seconds)
  end
  defp relative_time(%NaiveDateTime{} = dt) do
    {:ok, datetime} = DateTime.from_naive(dt, "Etc/UTC")
    relative_time(datetime)
  end

  defp format_relative_seconds(seconds) when seconds < 0, do: "just now"
  defp format_relative_seconds(seconds) when seconds < 60, do: "#{seconds}s ago"
  defp format_relative_seconds(seconds) when seconds < 3600, do: "#{div(seconds, 60)}m ago"
  defp format_relative_seconds(seconds) when seconds < 86400, do: "#{div(seconds, 3600)}h ago"
  defp format_relative_seconds(seconds), do: "#{div(seconds, 86400)}d ago"

  defp truncate(nil, _), do: ""
  defp truncate(str, max_length) when is_binary(str) do
    if String.length(str) > max_length do
      String.slice(str, 0, max_length) <> "..."
    else
      str
    end
  end
end
