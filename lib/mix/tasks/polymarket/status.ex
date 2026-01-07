defmodule Mix.Tasks.Polymarket.Status do
  @moduledoc """
  Display Polymarket Insider Detection system status.

  Shows dashboard statistics matching the UI at /admin/polymarket.

  ## Usage

      # Full dashboard overview
      mix polymarket.status

      # Investigation-focused stats
      mix polymarket.status --investigation

      # Feedback loop metrics
      mix polymarket.status --feedback

      # All stats combined
      mix polymarket.status --all

  ## Examples

      $ mix polymarket.status

      ═══════════════════════════════════════════════════════════════
      POLYMARKET INSIDER DETECTION - SYSTEM STATUS
      ═══════════════════════════════════════════════════════════════

      OVERVIEW
      ├─ Trades Scored:     2,199
      ├─ Markets:           350
      ├─ Wallets:           900
      └─ Active Patterns:   8

      ALERTS
      ├─ Total:    1
      ├─ New:      1
      └─ Critical: 0

      CANDIDATES
      ├─ Total:         5
      ├─ Undiscovered:  3
      ├─ Investigating: 2
      └─ Confirmed:     0
  """

  use Mix.Task
  alias VolfefeMachine.Polymarket

  @shortdoc "Display Polymarket system status"

  @impl Mix.Task
  def run(args) do
    Mix.Task.run("app.start")

    {opts, _, _} = OptionParser.parse(args,
      switches: [
        investigation: :boolean,
        feedback: :boolean,
        all: :boolean
      ],
      aliases: [i: :investigation, f: :feedback, a: :all]
    )

    show_all = opts[:all] || (!opts[:investigation] && !opts[:feedback])

    print_header()

    if show_all || (!opts[:investigation] && !opts[:feedback]) do
      print_overview()
      print_alerts()
      print_candidates()
    end

    if opts[:investigation] || opts[:all] do
      print_investigation()
    end

    if opts[:feedback] || opts[:all] do
      print_feedback()
    end

    print_footer()
  end

  defp print_header do
    Mix.shell().info("")
    Mix.shell().info(String.duplicate("═", 65))
    Mix.shell().info("POLYMARKET INSIDER DETECTION - SYSTEM STATUS")
    Mix.shell().info(String.duplicate("═", 65))
    Mix.shell().info("")
  end

  defp print_footer do
    Mix.shell().info(String.duplicate("─", 65))
    Mix.shell().info("Dashboard: /admin/polymarket")
    Mix.shell().info("")
  end

  defp print_overview do
    dashboard = Polymarket.monitoring_dashboard()
    inv = Polymarket.investigation_dashboard()

    Mix.shell().info("OVERVIEW")
    Mix.shell().info("├─ Alerts:            #{format_number(dashboard.alerts.total)}")
    Mix.shell().info("├─ Candidates:        #{format_number(inv.candidates.total)}")
    Mix.shell().info("├─ Confirmed Insiders: #{format_number(inv.confirmed_insiders.total)}")
    Mix.shell().info("└─ Active Patterns:   #{format_number(inv.patterns.active_patterns)}")
    Mix.shell().info("")
  end

  defp print_alerts do
    dashboard = Polymarket.monitoring_dashboard()
    alerts = dashboard.alerts

    Mix.shell().info("ALERTS")
    Mix.shell().info("├─ Total:      #{format_number(alerts.total)}")
    Mix.shell().info("├─ New:        #{format_number(alerts.new)}")
    Mix.shell().info("├─ Critical:   #{format_number(alerts.critical)}")
    Mix.shell().info("└─ Last 24h:   #{format_number(alerts.last_24h)}")
    Mix.shell().info("")
  end

  defp print_candidates do
    inv = Polymarket.investigation_dashboard()
    candidates = inv.candidates

    Mix.shell().info("CANDIDATES")
    Mix.shell().info("├─ Total:         #{format_number(candidates.total)}")

    by_status = candidates.by_status
    Mix.shell().info("├─ Undiscovered:  #{format_number(Map.get(by_status, "undiscovered", 0))}")
    Mix.shell().info("├─ Investigating: #{format_number(Map.get(by_status, "investigating", 0))}")
    Mix.shell().info("├─ Confirmed:     #{format_number(Map.get(by_status, "confirmed_insider", 0))}")
    Mix.shell().info("└─ Cleared:       #{format_number(Map.get(by_status, "cleared", 0))}")
    Mix.shell().info("")
  end

  defp print_investigation do
    inv = Polymarket.investigation_dashboard()
    candidates = inv.candidates

    Mix.shell().info("INVESTIGATION QUEUE")
    Mix.shell().info("├─ Total Candidates:   #{format_number(candidates.total)}")
    Mix.shell().info("├─ Undiscovered:       #{format_number(candidates.undiscovered)}")
    Mix.shell().info("├─ Investigating:      #{format_number(candidates.investigating)}")
    Mix.shell().info("└─ Resolved:           #{format_number(candidates.resolved)}")
    Mix.shell().info("")

    by_priority = candidates.by_priority
    Mix.shell().info("BY PRIORITY")
    Mix.shell().info("├─ Critical: #{format_number(Map.get(by_priority, "critical", 0))}")
    Mix.shell().info("├─ High:     #{format_number(Map.get(by_priority, "high", 0))}")
    Mix.shell().info("├─ Medium:   #{format_number(Map.get(by_priority, "medium", 0))}")
    Mix.shell().info("└─ Low:      #{format_number(Map.get(by_priority, "low", 0))}")
    Mix.shell().info("")
  end

  defp print_feedback do
    stats = Polymarket.feedback_loop_stats()

    Mix.shell().info("FEEDBACK LOOP STATUS")
    Mix.shell().info("")

    Mix.shell().info("Confirmed Insiders")
    Mix.shell().info("├─ Total:     #{format_number(stats.confirmed_insiders.total)}")
    Mix.shell().info("├─ Trained:   #{format_number(stats.confirmed_insiders.trained)}")
    Mix.shell().info("└─ Untrained: #{format_number(stats.confirmed_insiders.untrained)}")
    Mix.shell().info("")

    Mix.shell().info("Pattern Baselines")
    Mix.shell().info("├─ Total:              #{format_number(stats.baselines.total)}")
    Mix.shell().info("├─ With Insider Data:  #{format_number(stats.baselines.with_insider_data)}")
    Mix.shell().info("└─ Avg Separation:     #{format_float(stats.baselines.avg_separation_score)}")
    Mix.shell().info("")

    Mix.shell().info("Pattern Performance")
    Mix.shell().info("├─ Active Patterns:  #{format_number(stats.patterns.total)}")
    Mix.shell().info("├─ Avg F1 Score:     #{format_float(stats.patterns.avg_f1_score)}")
    Mix.shell().info("└─ Best F1 Score:    #{format_float(stats.patterns.best_f1_score)}")
    Mix.shell().info("")

    Mix.shell().info("Discovery")
    Mix.shell().info("├─ Total Batches:     #{format_number(stats.discovery.total_batches)}")
    Mix.shell().info("├─ Total Candidates:  #{format_number(stats.discovery.total_candidates)}")
    Mix.shell().info("└─ Resolved:          #{format_number(stats.discovery.resolved)}")
    Mix.shell().info("")

    # Show recommendations if available
    recs = Polymarket.feedback_loop_recommendations()
    if length(recs.recommendations) > 0 do
      Mix.shell().info("RECOMMENDATIONS")
      Enum.each(recs.recommendations, fn {priority, message} ->
        icon = case priority do
          :critical -> "🚨"
          :high -> "⚠️"
          :medium -> "📊"
          _ -> "ℹ️"
        end
        Mix.shell().info("#{icon} [#{priority}] #{message}")
      end)
      Mix.shell().info("")
    end
  end

  defp format_number(nil), do: "0"
  defp format_number(n) when is_integer(n), do: Integer.to_string(n)
  defp format_number(n), do: "#{n}"

  defp format_float(nil), do: "N/A"
  defp format_float(f) when is_float(f), do: Float.round(f, 4) |> Float.to_string()
  defp format_float(f), do: "#{f}"
end
