defmodule Mix.Tasks.Polymarket.Validate do
  @moduledoc """
  Validate pattern performance against current data.

  Re-evaluates all patterns against scored trades and confirmed insiders,
  updating precision, recall, F1 score, and lift metrics.

  ## Usage

      # Validate all patterns
      mix polymarket.validate

      # Validate specific pattern
      mix polymarket.validate --pattern whale_correct

  ## Options

      --pattern   Validate a specific pattern by name
      --verbose   Show detailed metrics for each pattern

  ## Examples

      $ mix polymarket.validate

      ═══════════════════════════════════════════════════════════════
      POLYMARKET VALIDATE
      ═══════════════════════════════════════════════════════════════

      Validating 8 patterns against 2,199 trades (5 confirmed insiders)...

      PATTERN RESULTS
      ┌──────────────────────┬────────────┬────────┬────────┬────────┐
      │ Pattern              │ Matches    │ Prec   │ Recall │ F1     │
      ├──────────────────────┼────────────┼────────┼────────┼────────┤
      │ whale_correct        │ 45         │ 0.11   │ 1.00   │ 0.20   │
      │ timing_extreme       │ 23         │ 0.17   │ 0.80   │ 0.28   │
      │ high_profit_timing   │ 12         │ 0.25   │ 0.60   │ 0.35   │
      └──────────────────────┴────────────┴────────┴────────┴────────┘

      ✅ Validated 8 patterns
         Best F1: 0.35 (high_profit_timing)
         Best Lift: 12.5x (timing_extreme)

  ## Metrics

  - **Precision**: True positives / all matches
  - **Recall**: True positives / all insiders
  - **F1 Score**: Harmonic mean of precision and recall
  - **Lift**: How much better than random selection
  """

  use Mix.Task
  alias VolfefeMachine.Polymarket

  @shortdoc "Validate pattern performance"

  @impl Mix.Task
  def run(args) do
    Mix.Task.run("app.start")

    {opts, _, _} = OptionParser.parse(args,
      switches: [
        pattern: :string,
        verbose: :boolean
      ],
      aliases: [p: :pattern, v: :verbose]
    )

    print_header()

    # Get pre-stats
    stats = Polymarket.feedback_loop_stats()
    pattern_count = stats.patterns.total
    insider_count = stats.confirmed_insiders.total

    if insider_count == 0 do
      Mix.shell().info("⚠️  No confirmed insiders available for validation")
      Mix.shell().info("")
      Mix.shell().info("Patterns need confirmed insiders to calculate precision/recall.")
      Mix.shell().info("Confirm some candidates first:")
      Mix.shell().info("  mix polymarket.candidates")
      Mix.shell().info("  mix polymarket.confirm --id ID")
    else
      Mix.shell().info("Validating #{pattern_count} patterns against #{insider_count} confirmed insiders...")
      Mix.shell().info("")

      case Polymarket.validate_patterns() do
        {:ok, result} ->
          print_results(result, opts[:verbose] || false)

        {:error, reason} ->
          Mix.shell().error("❌ Validation failed: #{inspect(reason)}")
      end
    end

    print_footer()
  end

  defp print_header do
    Mix.shell().info("")
    Mix.shell().info(String.duplicate("═", 65))
    Mix.shell().info("POLYMARKET VALIDATE")
    Mix.shell().info(String.duplicate("═", 65))
    Mix.shell().info("")
  end

  defp print_footer do
    Mix.shell().info(String.duplicate("─", 65))
    Mix.shell().info("View patterns: mix polymarket.patterns")
    Mix.shell().info("")
  end

  defp print_results(result, verbose) do
    Mix.shell().info("PATTERN RESULTS")

    # Table header
    Mix.shell().info("┌──────────────────────────┬────────┬────────┬────────┬────────┬────────┐")
    Mix.shell().info("│ Pattern                  │ TP/FP  │ Prec   │ Recall │ F1     │ Lift   │")
    Mix.shell().info("├──────────────────────────┼────────┼────────┼────────┼────────┼────────┤")

    # Sort by F1 score
    results = result.results |> Enum.sort_by(& &1.f1_score || 0, :desc)

    Enum.each(results, fn r ->
      name = String.pad_trailing(truncate(r.pattern_name, 24), 24)
      tp_fp = String.pad_trailing("#{r.true_positives}/#{r.false_positives}", 6)
      prec = String.pad_trailing(format_decimal_short(r.precision), 6)
      recall = String.pad_trailing(format_decimal_short(r.recall), 6)
      f1 = String.pad_trailing(format_decimal_short(r.f1_score), 6)
      lift = String.pad_trailing(format_lift(r.lift), 6)

      Mix.shell().info("│ #{name} │ #{tp_fp} │ #{prec} │ #{recall} │ #{f1} │ #{lift} │")
    end)

    Mix.shell().info("└──────────────────────────┴────────┴────────┴────────┴────────┴────────┘")
    Mix.shell().info("")

    # Summary
    Mix.shell().info("✅ Validated #{result.validated} patterns")

    best_f1 = results |> Enum.filter(& &1.f1_score) |> Enum.max_by(& &1.f1_score, fn -> nil end)
    if best_f1 do
      Mix.shell().info("   Best F1: #{format_decimal_short(best_f1.f1_score)} (#{best_f1.pattern_name})")
    end

    best_lift = results |> Enum.filter(& &1.lift) |> Enum.max_by(& &1.lift, fn -> nil end)
    if best_lift && best_lift.lift > 1 do
      Mix.shell().info("   Best Lift: #{format_lift(best_lift.lift)} (#{best_lift.pattern_name})")
    end

    Mix.shell().info("")

    if verbose do
      Mix.shell().info("Totals:")
      Mix.shell().info("├─ Trades evaluated: #{result.total_trades}")
      Mix.shell().info("└─ Confirmed insiders: #{result.total_insiders}")
      Mix.shell().info("")
    end
  end

  defp format_decimal_short(nil), do: "N/A"
  defp format_decimal_short(f) when is_float(f), do: Float.round(f, 2) |> Float.to_string()
  defp format_decimal_short(%Decimal{} = d), do: Decimal.round(d, 2) |> Decimal.to_string()
  defp format_decimal_short(n), do: "#{n}"

  defp format_lift(nil), do: "N/A"
  defp format_lift(f) when is_float(f) and f > 100, do: ">100x"
  defp format_lift(f) when is_float(f), do: "#{Float.round(f, 1)}x"
  defp format_lift(n), do: "#{n}x"

  defp truncate(nil, _), do: ""
  defp truncate(str, max_length) when is_binary(str) do
    if String.length(str) > max_length do
      String.slice(str, 0, max_length - 2) <> ".."
    else
      str
    end
  end
end
