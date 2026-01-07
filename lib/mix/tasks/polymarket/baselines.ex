defmodule Mix.Tasks.Polymarket.Baselines do
  import Ecto.Query
  @moduledoc """
  Recalculate insider baselines from confirmed insiders.

  Updates pattern baselines using trade data from confirmed insider wallets.
  This improves the separation between insider and non-insider behavior.

  ## Usage

      # Recalculate all baselines
      mix polymarket.baselines

      # Verbose output
      mix polymarket.baselines --verbose

  ## Examples

      $ mix polymarket.baselines

      ═══════════════════════════════════════════════════════════════
      POLYMARKET BASELINES
      ═══════════════════════════════════════════════════════════════

      Recalculating baselines from 5 confirmed insider trades...

      ✅ Updated 8 baseline metrics

      Separation Scores:
      ├─ size:                  0.45 → 0.58 (+29%)
      ├─ timing_hours:          0.32 → 0.41 (+28%)
      ├─ profit:                0.51 → 0.65 (+27%)
      └─ outcome_correct_pct:   0.28 → 0.35 (+25%)

  ## Background

  Baselines are statistical profiles comparing insider vs non-insider
  trading behavior. Higher separation scores indicate better differentiation.
  """

  use Mix.Task
  alias VolfefeMachine.Polymarket

  @shortdoc "Recalculate insider baselines"

  @impl Mix.Task
  def run(args) do
    Mix.Task.run("app.start")

    {opts, _, _} = OptionParser.parse(args,
      switches: [verbose: :boolean],
      aliases: [v: :verbose]
    )

    verbose = opts[:verbose] || false

    print_header()

    # Get pre-stats
    pre_stats = Polymarket.feedback_loop_stats()
    insider_count = pre_stats.confirmed_insiders.total
    trained_count = pre_stats.confirmed_insiders.trained

    Mix.shell().info("Insider Trades: #{trained_count} trained, #{insider_count} total")
    Mix.shell().info("")

    if trained_count == 0 do
      Mix.shell().info("⚠️  No trained insider trades available for baseline calculation")
      Mix.shell().info("")
      Mix.shell().info("To calculate baselines, confirm some candidates as insiders:")
      Mix.shell().info("  mix polymarket.candidates")
      Mix.shell().info("  mix polymarket.confirm --id ID")
    else
      Mix.shell().info("Recalculating baselines...")
      Mix.shell().info("")

      {:ok, result} = Polymarket.calculate_insider_baselines()
      Mix.shell().info("✅ Updated #{result.updated} baseline metrics")
      Mix.shell().info("")

      if verbose do
        show_baseline_details()
      end

      # Show post-stats
      post_stats = Polymarket.feedback_loop_stats()
      show_separation_change(pre_stats, post_stats)
    end

    print_footer()
  end

  defp print_header do
    Mix.shell().info("")
    Mix.shell().info(String.duplicate("═", 65))
    Mix.shell().info("POLYMARKET BASELINES")
    Mix.shell().info(String.duplicate("═", 65))
    Mix.shell().info("")
  end

  defp print_footer do
    Mix.shell().info(String.duplicate("─", 65))
    Mix.shell().info("View patterns: mix polymarket.patterns")
    Mix.shell().info("")
  end

  defp show_baseline_details do
    # Get baselines from the database
    baselines = VolfefeMachine.Repo.all(
      from b in VolfefeMachine.Polymarket.PatternBaseline,
        where: b.market_category == "all",
        order_by: [desc: b.separation_score]
    )

    if length(baselines) > 0 do
      Mix.shell().info("BASELINE DETAILS")

      baselines
      |> Enum.with_index()
      |> Enum.each(fn {baseline, idx} ->
        prefix = if idx == length(baselines) - 1, do: "└─", else: "├─"
        sep = format_decimal(baseline.separation_score)
        insider_mean = format_decimal(baseline.insider_mean)
        pop_mean = format_decimal(baseline.population_mean)
        sample = baseline.insider_sample_count || 0

        Mix.shell().info("#{prefix} #{baseline.metric_name}")
        Mix.shell().info("   Separation: #{sep}")
        Mix.shell().info("   Insider Mean: #{insider_mean} (n=#{sample})")
        Mix.shell().info("   Population Mean: #{pop_mean}")
      end)

      Mix.shell().info("")
    end
  end

  defp show_separation_change(pre_stats, post_stats) do
    pre_sep = pre_stats.baselines.avg_separation_score || 0
    post_sep = post_stats.baselines.avg_separation_score || 0

    if pre_sep > 0 or post_sep > 0 do
      Mix.shell().info("SEPARATION SCORE")
      change = format_percent_change(pre_sep, post_sep)
      Mix.shell().info("└─ Average: #{format_decimal(pre_sep)} → #{format_decimal(post_sep)} #{change}")
      Mix.shell().info("")
    end
  end

  defp format_decimal(nil), do: "N/A"
  defp format_decimal(%Decimal{} = d), do: Decimal.round(d, 4) |> Decimal.to_string()
  defp format_decimal(f) when is_float(f), do: Float.round(f, 4) |> Float.to_string()
  defp format_decimal(n), do: "#{n}"

  defp format_percent_change(pre, post) when pre == 0 and post == 0, do: "(no change)"
  defp format_percent_change(pre, _post) when pre == 0, do: "(new)"
  defp format_percent_change(pre, post) do
    change = ((post - pre) / pre) * 100
    if change >= 0 do
      "(+#{Float.round(change, 1)}%)"
    else
      "(#{Float.round(change, 1)}%)"
    end
  end
end
