defmodule Mix.Tasks.Polymarket.ValidatePredictions do
  @moduledoc """
  Validate forward predictions against actual market outcomes.

  Checks pending predictions for markets that have now resolved and
  calculates forward prediction accuracy metrics.

  ## Usage

      # Validate pending predictions and show results
      mix polymarket.validate_predictions

      # Show accuracy stats only (no validation)
      mix polymarket.validate_predictions --stats

      # Show all predictions (including already validated)
      mix polymarket.validate_predictions --show-all

      # Verbose output with details
      mix polymarket.validate_predictions --verbose

  ## Options

      --stats       Show accuracy statistics only
      --show-all    Include already validated predictions
      --verbose     Show detailed output

  ## Output

      PREDICTION VALIDATION RESULTS
      ═══════════════════════════════════════════════════════════════

      Validated 3 new predictions:

      #1 [CORRECT] Will Bitcoin hit $150K by March?
         Predicted: Yes (0.82 confidence) | Actual: Yes
         Lead time: 12.3 days | Watchability: 0.89

      #2 [INCORRECT] Will Fed cut rates in January?
         Predicted: Yes (0.65 confidence) | Actual: No
         Lead time: 5.1 days | Watchability: 0.71

      ───────────────────────────────────────────────────────────────
      FORWARD PREDICTION ACCURACY
      ───────────────────────────────────────────────────────────────
      Total Predictions: 47
      Validated: 23
      Pending: 24

      Accuracy by Tier:
        Critical (≥0.8): 85.7% (6/7)
        High (≥0.6):     72.2% (13/18)
        Medium (≥0.4):   58.3% (7/12)
        Overall:         69.2% (27/39)

      Avg Lead Time: 8.4 days before resolution
  """

  use Mix.Task
  require Logger

  alias VolfefeMachine.Polymarket

  @shortdoc "Validate forward predictions against market outcomes"

  @impl Mix.Task
  def run(args) do
    Mix.Task.run("app.start")

    {opts, _, _} = OptionParser.parse(args,
      switches: [
        stats: :boolean,
        show_all: :boolean,
        verbose: :boolean
      ],
      aliases: [s: :stats, a: :show_all, v: :verbose]
    )

    stats_only = opts[:stats] || false
    show_all = opts[:show_all] || false
    verbose = opts[:verbose] || false

    print_header()

    if stats_only do
      display_stats()
    else
      # Run validation
      validation_result = Polymarket.auto_validate_predictions()

      if length(validation_result.results) > 0 do
        Mix.shell().info("Validated #{validation_result.validated} new predictions:\n")
        display_validated(validation_result.results, verbose)
      else
        pending = Polymarket.list_pending_predictions()
        Mix.shell().info("No new validations (#{length(pending)} predictions still pending)")
      end

      # Show all if requested
      if show_all do
        Mix.shell().info("")
        Mix.shell().info(String.duplicate("─", 65))
        Mix.shell().info("ALL PREDICTIONS")
        Mix.shell().info(String.duplicate("─", 65))
        display_all_predictions(verbose)
      end

      # Always show stats
      Mix.shell().info("")
      display_stats()
    end

    print_footer()
  end

  defp display_validated(results, verbose) do
    Enum.with_index(results, 1)
    |> Enum.each(fn {result, idx} ->
      status = if result.correct, do: "[CORRECT]", else: "[INCORRECT]"
      color_status = if result.correct, do: status, else: status

      Mix.shell().info("##{idx} #{color_status} #{truncate(result.market_question, 45)}")
      Mix.shell().info("   Predicted: #{result.predicted} | Actual: #{result.actual}")

      if verbose do
        Mix.shell().info("   Prediction ID: #{result.prediction_id}")
      end

      Mix.shell().info("")
    end)
  end

  defp display_all_predictions(verbose) do
    predictions = Polymarket.list_predictions(limit: 50)

    if length(predictions) == 0 do
      Mix.shell().info("No predictions recorded yet.")
    else
      Enum.with_index(predictions, 1)
      |> Enum.each(fn {prediction, idx} ->
        status = cond do
          is_nil(prediction.validated_at) -> "[PENDING]"
          prediction.prediction_correct -> "[CORRECT]"
          true -> "[INCORRECT]"
        end

        tier = tier_badge(prediction.prediction_tier)
        question = truncate(prediction.market_question, 40)
        confidence = format_confidence(prediction.prediction_confidence)

        Mix.shell().info("##{idx} #{status} #{tier} #{question}")
        Mix.shell().info("   Predicted: #{prediction.predicted_outcome} (#{confidence}) | Watchability: #{format_score(prediction.watchability_score)}")

        if prediction.validated_at do
          Mix.shell().info("   Actual: #{prediction.actual_outcome} | Lead time: #{format_days(prediction.days_before_resolution)}")
        else
          days_to_end = if prediction.market_end_date do
            DateTime.diff(prediction.market_end_date, DateTime.utc_now(), :second) / 86400
          end
          Mix.shell().info("   Ends in: #{format_days_until(days_to_end)}")
        end

        if verbose do
          Mix.shell().info("   Category: #{prediction.market_category} | Condition: #{prediction.condition_id}")
          Mix.shell().info("   Recorded: #{format_datetime(prediction.predicted_at)}")
        end

        Mix.shell().info("")
      end)
    end
  end

  defp display_stats do
    stats = Polymarket.prediction_stats()

    Mix.shell().info(String.duplicate("─", 65))
    Mix.shell().info("FORWARD PREDICTION ACCURACY")
    Mix.shell().info(String.duplicate("─", 65))

    Mix.shell().info("Total Predictions: #{stats.total_predictions}")
    Mix.shell().info("Validated: #{stats.validated}")
    Mix.shell().info("Pending: #{stats.pending}")
    Mix.shell().info("")

    if stats.validated > 0 do
      Mix.shell().info("Accuracy by Tier:")

      # Order tiers
      tiers = ["critical", "high", "medium", "low"]
      Enum.each(tiers, fn tier ->
        case Map.get(stats.accuracy_by_tier, tier) do
          nil -> :ok
          tier_stats ->
            label = case tier do
              "critical" -> "  Critical (≥0.8):"
              "high" -> "  High (≥0.6):    "
              "medium" -> "  Medium (≥0.4): "
              "low" -> "  Low (<0.4):     "
            end
            Mix.shell().info("#{label} #{tier_stats.accuracy}% (#{tier_stats.correct}/#{tier_stats.total})")
        end
      end)

      Mix.shell().info("")
      Mix.shell().info("Overall Accuracy: #{stats.accuracy}% (#{stats.correct}/#{stats.validated})")

      if stats.avg_lead_time do
        Mix.shell().info("Avg Lead Time: #{stats.avg_lead_time} days before resolution")
      end
    else
      Mix.shell().info("No validated predictions yet.")
    end
  end

  # Formatting helpers
  defp tier_badge("critical"), do: "[CRIT]"
  defp tier_badge("high"), do: "[HIGH]"
  defp tier_badge("medium"), do: "[MED]"
  defp tier_badge("low"), do: "[LOW]"
  defp tier_badge(_), do: "[???]"

  defp format_score(nil), do: "N/A"
  defp format_score(%Decimal{} = d), do: Decimal.round(d, 2) |> Decimal.to_string()
  defp format_score(n) when is_number(n), do: Float.round(n * 1.0, 2) |> to_string()

  defp format_confidence(nil), do: "N/A"
  defp format_confidence(%Decimal{} = d) do
    pct = Decimal.mult(d, 100) |> Decimal.round(0) |> Decimal.to_integer()
    "#{pct}%"
  end
  defp format_confidence(n) when is_number(n), do: "#{round(n * 100)}%"

  defp format_days(nil), do: "N/A"
  defp format_days(%Decimal{} = d), do: "#{Decimal.round(d, 1)} days"
  defp format_days(n) when is_number(n), do: "#{Float.round(n * 1.0, 1)} days"

  defp format_days_until(nil), do: "unknown"
  defp format_days_until(days) when days <= 0, do: "ended"
  defp format_days_until(days) when days < 1, do: "< 1 day"
  defp format_days_until(days), do: "#{Float.round(days, 1)} days"

  defp format_datetime(nil), do: "N/A"
  defp format_datetime(dt), do: Calendar.strftime(dt, "%Y-%m-%d %H:%M UTC")

  defp truncate(nil, _), do: ""
  defp truncate(str, max) when byte_size(str) > max do
    String.slice(str, 0, max - 3) <> "..."
  end
  defp truncate(str, _), do: str

  defp print_header do
    Mix.shell().info("")
    Mix.shell().info("╔══════════════════════════════════════════════════════════════╗")
    Mix.shell().info("║ PREDICTION VALIDATION RESULTS                                ║")
    Mix.shell().info("╚══════════════════════════════════════════════════════════════╝")
    Mix.shell().info("")
  end

  defp print_footer do
    Mix.shell().info("")
    Mix.shell().info("Next steps:")
    Mix.shell().info("  • Record new predictions: mix polymarket.predict")
    Mix.shell().info("  • Scan active markets: mix polymarket.scan_active")
    Mix.shell().info("")
  end
end
