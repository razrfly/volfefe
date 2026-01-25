defmodule Mix.Tasks.Polymarket.Health do
  @moduledoc """
  Check pipeline health, coverage diversity, and data source status.

  Quick health check for the wide-net ingestion pipeline.
  Shows any issues with coverage, staleness, concentration, or API availability.

  ## Usage

      # Check health status
      mix polymarket.health

      # Show full category breakdown
      mix polymarket.health --full

      # Show data source health (API vs Subgraph)
      mix polymarket.health --sources

      # JSON output for monitoring
      mix polymarket.health --json

  ## Examples

      $ mix polymarket.health --sources

      ═══════════════════════════════════════════════════════════════
      DATA SOURCE HEALTH
      ═══════════════════════════════════════════════════════════════

      Centralized API:
        Status: ❌ unhealthy
        Success Rate: 0.0%
        Last Failure: timeout

      Blockchain Subgraph:
        Status: ✅ healthy
        Success Rate: 100.0%
        Last Success: 2s ago

      🔗 Recommended Source: subgraph

      $ mix polymarket.health

      ═══════════════════════════════════════════════════════════════
      PIPELINE HEALTH CHECK
      ═══════════════════════════════════════════════════════════════

      ✅ Health Score: 75/100
         Categories Active: 5/8
         Markets with Trades: 120/450
         Total Trades: 12,340
         Scored Trades: 8,200

         Concentration: 45.2% from politics

      ⚠️  ALERTS (2):
         ⚠️  corporate: No trades captured (8 markets available)
         ⚠️  science: Stale data (3h since last trade)

      ─────────────────────────────────────────────────────────────────
      Full report: mix polymarket.coverage
      Ingest trades: mix polymarket.ingest
  """

  use Mix.Task
  alias VolfefeMachine.Polymarket.DiversityMonitor
  alias VolfefeMachine.Polymarket.DataSourceHealth

  @shortdoc "Check pipeline health and coverage diversity"

  @impl Mix.Task
  def run(args) do
    Mix.Task.run("app.start")

    {opts, _, _} = OptionParser.parse(args,
      switches: [
        full: :boolean,
        json: :boolean,
        sources: :boolean
      ],
      aliases: [f: :full, j: :json, s: :sources]
    )

    cond do
      opts[:json] ->
        print_json()

      opts[:sources] ->
        print_source_health()

      true ->
        print_header()
        print_health_check(opts[:full])
        print_footer()
    end
  end

  defp print_source_health do
    Mix.shell().info("")
    Mix.shell().info(String.duplicate("═", 65))
    Mix.shell().info("DATA SOURCE HEALTH")
    Mix.shell().info(String.duplicate("═", 65))
    Mix.shell().info("")

    # Force a health check
    case DataSourceHealth.check_now() do
      {:ok, summary} ->
        # API Health
        Mix.shell().info("Centralized API:")
        print_source_status(summary.api)
        Mix.shell().info("")

        # Subgraph Health
        Mix.shell().info("Blockchain Subgraph:")
        print_source_status(summary.subgraph)
        Mix.shell().info("")

        # Recommendation
        Mix.shell().info(String.duplicate("─", 65))
        rec = summary.recommended_source
        icon = if rec == :subgraph, do: "🔗", else: "🌐"
        Mix.shell().info("#{icon} Recommended Source: #{rec}")

        # Uptime
        if summary.uptime_seconds > 0 do
          Mix.shell().info("   Monitor uptime: #{format_uptime(summary.uptime_seconds)}")
        end

        Mix.shell().info("")

      {:error, :not_running} ->
        Mix.shell().error("DataSourceHealth monitor not running")
        Mix.shell().info("")
    end
  end

  defp print_source_status(source) do
    status_icon = if source.healthy, do: "✅", else: "❌"
    status_text = if source.healthy, do: "healthy", else: "unhealthy"
    success_rate = Float.round(source.success_rate * 100, 1)

    Mix.shell().info("  Status: #{status_icon} #{status_text}")
    Mix.shell().info("  Success Rate: #{success_rate}%")

    if source.last_success do
      Mix.shell().info("  Last Success: #{format_time_ago(source.last_success)}")
    end

    if source.last_failure do
      Mix.shell().info("  Last Failure: #{format_time_ago(source.last_failure)}")
    end
  end

  defp format_uptime(seconds) when seconds < 60, do: "#{seconds}s"
  defp format_uptime(seconds) when seconds < 3600, do: "#{div(seconds, 60)}m #{rem(seconds, 60)}s"
  defp format_uptime(seconds) do
    hours = div(seconds, 3600)
    mins = div(rem(seconds, 3600), 60)
    "#{hours}h #{mins}m"
  end

  defp print_json do
    summary = DiversityMonitor.health_summary()

    json = Jason.encode!(summary, pretty: true)
    Mix.shell().info(json)
  end

  defp print_health_check(full) do
    summary = DiversityMonitor.health_summary()

    # Health score with color indicator
    score_indicator = cond do
      summary.health_score >= 80 -> "✅"
      summary.health_score >= 50 -> "⚠️"
      true -> "❌"
    end

    Mix.shell().info("#{score_indicator} Health Score: #{summary.health_score}/100")
    Mix.shell().info("   Categories Active: #{summary.categories_active}/#{summary.categories_total}")
    Mix.shell().info("   Markets with Trades: #{format_number(summary.markets_with_trades)}/#{format_number(summary.total_markets)}")
    Mix.shell().info("   Total Trades: #{format_number(summary.total_trades)}")
    Mix.shell().info("   Scored Trades: #{format_number(summary.scored_trades)}")
    Mix.shell().info("")

    # Concentration
    if summary.concentration.is_concerning do
      Mix.shell().info("⚠️  Concentration: #{summary.concentration.percentage}% from #{summary.concentration.top_category}")
    else
      Mix.shell().info("   Concentration: #{summary.concentration.percentage}% from #{summary.concentration.top_category || "N/A"}")
    end

    Mix.shell().info("")

    # Alerts
    if summary.alert_count > 0 do
      case DiversityMonitor.check_alerts() do
        {:alerts, alerts} ->
          Mix.shell().info("⚠️  ALERTS (#{length(alerts)}):")
          Enum.each(alerts, fn alert ->
            icon = case alert.severity do
              :critical -> "❌"
              :warning -> "⚠️"
              :info -> "ℹ️"
            end
            Mix.shell().info("   #{icon} #{alert.message}")
          end)
        _ -> :ok
      end
    else
      Mix.shell().info("✅ No alerts - coverage looks healthy!")
    end

    Mix.shell().info("")

    if full do
      print_category_breakdown()
    end
  end

  defp print_category_breakdown do
    coverage = DiversityMonitor.get_coverage()

    Mix.shell().info("CATEGORY BREAKDOWN")
    Mix.shell().info("─────────────────────────────────────────")

    Enum.each(coverage.categories, fn cat ->
      status = cond do
        cat.is_critical -> "❌ CRITICAL"
        cat.is_stale -> "⚠️  STALE"
        cat.is_missing -> "⚠️  MISSING"
        cat.trades > 0 -> "✅ OK"
        true -> "   --"
      end

      last = if cat.last_trade do
        format_time_ago(cat.last_trade)
      else
        "never"
      end

      name = String.pad_trailing(to_string(cat.category), 14)
      trades = String.pad_leading(format_number(cat.trades), 8)
      Mix.shell().info("  #{name} #{trades} trades   last: #{last}   #{status}")
    end)

    Mix.shell().info("")
  end

  defp format_time_ago(dt) do
    seconds = DateTime.diff(DateTime.utc_now(), dt, :second)

    cond do
      seconds < 60 -> "#{seconds}s ago"
      seconds < 3600 -> "#{div(seconds, 60)}m ago"
      seconds < 86400 -> "#{div(seconds, 3600)}h ago"
      true -> "#{div(seconds, 86400)}d ago"
    end
  end

  defp format_number(n) when is_integer(n) do
    n
    |> Integer.to_string()
    |> String.reverse()
    |> String.replace(~r/(\d{3})(?=\d)/, "\\1,")
    |> String.reverse()
  end
  defp format_number(n), do: "#{n}"

  defp print_header do
    Mix.shell().info("")
    Mix.shell().info(String.duplicate("═", 65))
    Mix.shell().info("PIPELINE HEALTH CHECK")
    Mix.shell().info(String.duplicate("═", 65))
    Mix.shell().info("")
  end

  defp print_footer do
    Mix.shell().info(String.duplicate("─", 65))
    Mix.shell().info("Full report: mix polymarket.coverage")
    Mix.shell().info("Ingest trades: mix polymarket.ingest")
    Mix.shell().info("")
  end
end
