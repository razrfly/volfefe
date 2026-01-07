defmodule Mix.Tasks.Polymarket.Alerts do
  @moduledoc """
  List Polymarket insider detection alerts.

  Displays alerts matching the Alerts tab in /admin/polymarket.

  ## Usage

      # All alerts (default limit 50)
      mix polymarket.alerts

      # Filter by status
      mix polymarket.alerts --status new
      mix polymarket.alerts --status investigating

      # Filter by severity
      mix polymarket.alerts --severity critical
      mix polymarket.alerts --severity high

      # Combine filters
      mix polymarket.alerts --status new --severity critical --limit 10

  ## Options

      --status    Filter by status (new, acknowledged, investigating, resolved, dismissed)
      --severity  Filter by severity (critical, high, medium, low)
      --limit     Maximum alerts to show (default: 50)
      --verbose   Show full alert details

  ## Examples

      $ mix polymarket.alerts --status new

      POLYMARKET ALERTS (3 total)
      ═══════════════════════════════════════════════════════════════

      #1 [CRITICAL] 0x348a...f2c1
         Severity: critical | Status: new
         Probability: 89.5% | Anomaly: 0.92
         Triggered: 2h ago
         Market: Will Trump win the 2024 election?

      #2 [HIGH] 0x7b2e...a891
         ...
  """

  use Mix.Task
  alias VolfefeMachine.Polymarket

  @shortdoc "List Polymarket alerts"

  @impl Mix.Task
  def run(args) do
    Mix.Task.run("app.start")

    {opts, _, _} = OptionParser.parse(args,
      switches: [
        status: :string,
        severity: :string,
        limit: :integer,
        verbose: :boolean
      ],
      aliases: [s: :status, v: :verbose, l: :limit]
    )

    list_opts = [limit: opts[:limit] || 50]
    list_opts = if opts[:status], do: Keyword.put(list_opts, :status, opts[:status]), else: list_opts
    list_opts = if opts[:severity], do: Keyword.put(list_opts, :severity, opts[:severity]), else: list_opts

    alerts = Polymarket.list_alerts(list_opts)

    print_alerts(alerts, opts[:verbose] || false)
  end

  defp print_alerts([], _verbose) do
    Mix.shell().info("")
    Mix.shell().info("No alerts found matching criteria.")
    Mix.shell().info("")
  end

  defp print_alerts(alerts, verbose) do
    Mix.shell().info("")
    Mix.shell().info("POLYMARKET ALERTS (#{length(alerts)} total)")
    Mix.shell().info(String.duplicate("═", 65))
    Mix.shell().info("")

    Enum.each(alerts, fn alert ->
      print_alert(alert, verbose)
    end)

    Mix.shell().info(String.duplicate("─", 65))
    Mix.shell().info("Use --verbose for full details")
    Mix.shell().info("")
  end

  defp print_alert(alert, verbose) do
    severity_icon = severity_icon(alert.severity)
    wallet = format_wallet(alert.wallet_address)

    Mix.shell().info("#{severity_icon} ##{alert.id} [#{String.upcase(alert.severity)}] #{wallet}")
    Mix.shell().info("   Severity: #{alert.severity} | Status: #{alert.status}")

    prob = format_probability(alert.insider_probability)
    anomaly = format_decimal(alert.anomaly_score)
    Mix.shell().info("   Probability: #{prob} | Anomaly: #{anomaly}")

    Mix.shell().info("   Triggered: #{relative_time(alert.triggered_at)}")

    if alert.market_question do
      question = truncate(alert.market_question, 50)
      Mix.shell().info("   Market: #{question}")
    end

    if verbose do
      Mix.shell().info("   Pattern: #{alert.pattern_name || "N/A"}")
      Mix.shell().info("   Trade ID: #{alert.trade_id || "N/A"}")
      if alert.acknowledged_at do
        Mix.shell().info("   Acknowledged: #{relative_time(alert.acknowledged_at)} by #{alert.acknowledged_by}")
      end
    end

    Mix.shell().info("")
  end

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
  defp format_probability(%Decimal{} = d) do
    "#{Decimal.round(Decimal.mult(d, 100), 1)}%"
  end
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
