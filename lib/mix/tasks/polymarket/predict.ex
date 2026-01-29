defmodule Mix.Tasks.Polymarket.Predict do
  @moduledoc """
  Record forward predictions on active markets with suspicious activity.

  Scans active markets for suspicious trading patterns and records
  predictions BEFORE market resolution for later validation.

  ## Usage

      # Record predictions on suspicious active markets
      mix polymarket.predict

      # Limit to top N markets by watchability
      mix polymarket.predict --limit 10

      # Filter by minimum watchability score
      mix polymarket.predict --min-score 0.6

      # Filter by category
      mix polymarket.predict --category crypto

      # Filter by markets ending within N days
      mix polymarket.predict --ending-within 7

      # Dry run (show what would be predicted without saving)
      mix polymarket.predict --dry-run

  ## Options

      --limit           Maximum predictions to record (default: 20)
      --min-score       Minimum watchability score (default: 0.5)
      --category        Filter by category (crypto, politics, sports, etc.)
      --ending-within   Only markets ending within N days
      --dry-run         Show predictions without saving
      --verbose         Show detailed output

  ## Output

      FORWARD PREDICTION RECORDING
      ═══════════════════════════════════════════════════════════════

      Recording 5 predictions...

      #1 [CRITICAL] Will Bitcoin hit $150K by March?
         Watchability: 0.89 | Predicted: Yes (0.82 confidence)
         Suspicious Volume: $45K Yes / $8K No (85% consensus)
         Top Wallet: 0x4ffe...09f71 (score: 0.94)
         Ends in: 12.3 days

      #2 [HIGH] Will Fed cut rates in January?
         ...

      ───────────────────────────────────────────────────────────────
      Recorded 5 new predictions | Skipped 3 (recent predictions exist)
  """

  use Mix.Task
  require Logger

  alias VolfefeMachine.Polymarket
  alias VolfefeMachine.Polymarket.Prediction

  @shortdoc "Record forward predictions on suspicious active markets"

  @default_limit 20
  @default_min_score 0.5

  @impl Mix.Task
  def run(args) do
    Mix.Task.run("app.start")

    {opts, _, _} = OptionParser.parse(args,
      switches: [
        limit: :integer,
        min_score: :float,
        category: :string,
        ending_within: :integer,
        dry_run: :boolean,
        verbose: :boolean
      ],
      aliases: [l: :limit, m: :min_score, c: :category, e: :ending_within, d: :dry_run, v: :verbose]
    )

    limit = opts[:limit] || @default_limit
    min_score = opts[:min_score] || @default_min_score
    category = opts[:category]
    ending_within = opts[:ending_within]
    dry_run = opts[:dry_run] || false
    verbose = opts[:verbose] || false

    print_header(dry_run)

    # Find markets for prediction
    markets = Polymarket.find_markets_for_prediction(min_score,
      category: category,
      ending_within: ending_within,
      limit: limit * 2  # Fetch more to account for skips
    )

    if length(markets) == 0 do
      Mix.shell().info("No active markets found with suspicious activity (min_score: #{min_score})")
    else
      Mix.shell().info("Found #{length(markets)} suspicious active markets\n")

      # Process each market
      {recorded, skipped, results} = process_markets(markets, limit, dry_run, verbose)

      # Display results
      display_results(results, verbose)

      # Summary
      Mix.shell().info("")
      Mix.shell().info(String.duplicate("─", 65))

      if dry_run do
        Mix.shell().info("DRY RUN: Would record #{recorded} predictions | #{skipped} already have recent predictions")
      else
        Mix.shell().info("Recorded #{recorded} new predictions | Skipped #{skipped} (recent predictions exist)")
      end

      # Show current stats
      stats = Polymarket.prediction_stats()
      Mix.shell().info("")
      Mix.shell().info("Total predictions: #{stats.total_predictions} | Pending validation: #{stats.pending}")
    end

    print_footer()
  end

  defp process_markets(markets, limit, dry_run, verbose) do
    now = DateTime.utc_now()

    {recorded, skipped, results} = Enum.reduce_while(markets, {0, 0, []}, fn market_data, {rec, skip, acc} ->
      if rec >= limit do
        {:halt, {rec, skip, acc}}
      else
        condition_id = market_data.market.condition_id

        # Check if recent prediction exists
        if Polymarket.prediction_exists?(condition_id, 24) do
          if verbose do
            Mix.shell().info("  Skipping #{truncate(market_data.market.question, 40)} (recent prediction exists)")
          end
          {:cont, {rec, skip + 1, acc}}
        else
          # Build prediction
          prediction_result = build_and_save_prediction(market_data, now, dry_run)

          case prediction_result do
            {:ok, prediction_data} ->
              {:cont, {rec + 1, skip, acc ++ [prediction_data]}}
            {:error, _reason} ->
              {:cont, {rec, skip + 1, acc}}
          end
        end
      end
    end)

    {recorded, skipped, results}
  end

  defp build_and_save_prediction(market_data, now, dry_run) do
    # Determine predicted outcome from volume consensus
    {predicted_outcome, confidence} = Prediction.determine_prediction(
      market_data.yes_volume,
      market_data.no_volume
    )

    prediction_id = Prediction.generate_prediction_id(
      market_data.market.condition_id,
      now
    )

    attrs = %{
      prediction_id: prediction_id,
      market_id: market_data.market.id,
      condition_id: market_data.market.condition_id,
      market_question: market_data.market.question,
      market_category: to_string(market_data.market.category),
      predicted_at: now,
      market_end_date: market_data.market.end_date,
      watchability_score: Decimal.from_float(market_data.watchability),
      max_ensemble_score: market_data.max_ensemble,
      avg_ensemble_score: market_data.avg_ensemble,
      suspicious_trade_count: market_data.suspicious_trade_count,
      suspicious_volume: market_data.suspicious_volume,
      unique_suspicious_wallets: market_data.unique_wallets,
      top_wallet_address: market_data.top_wallet && market_data.top_wallet.wallet_address,
      top_wallet_score: market_data.top_wallet && market_data.top_wallet.max_score,
      top_wallet_trade_count: market_data.top_wallet && market_data.top_wallet.trade_count,
      predicted_outcome: predicted_outcome,
      prediction_confidence: confidence,
      prediction_tier: market_data.tier,
      suspicious_yes_volume: market_data.yes_volume,
      suspicious_no_volume: market_data.no_volume
    }

    if dry_run do
      {:ok, attrs}
    else
      case Polymarket.create_prediction(attrs) do
        {:ok, _prediction} -> {:ok, attrs}
        {:error, changeset} ->
          Logger.warning("Failed to create prediction: #{inspect(changeset.errors)}")
          {:error, changeset}
      end
    end
  end

  defp display_results(results, verbose) do
    Enum.with_index(results, 1)
    |> Enum.each(fn {data, idx} ->
      display_prediction(data, idx, verbose)
    end)
  end

  defp display_prediction(data, idx, verbose) do
    tier_badge = tier_badge(data.prediction_tier)
    question = truncate(data.market_question || "Unknown", 50)

    confidence_pct = Float.round(Decimal.to_float(data.prediction_confidence) * 100, 0)

    # Volume breakdown
    yes_vol = format_money(decimal_to_float(data.suspicious_yes_volume))
    no_vol = format_money(decimal_to_float(data.suspicious_no_volume))
    total_vol = decimal_to_float(data.suspicious_yes_volume) + decimal_to_float(data.suspicious_no_volume)
    consensus_pct = if total_vol > 0 do
      winner_vol = max(decimal_to_float(data.suspicious_yes_volume), decimal_to_float(data.suspicious_no_volume))
      Float.round(winner_vol / total_vol * 100, 0)
    else
      50
    end

    Mix.shell().info("##{idx} #{tier_badge} #{question}")
    Mix.shell().info("   Watchability: #{format_score(data.watchability_score)} | Predicted: #{data.predicted_outcome} (#{confidence_pct}% confidence)")
    Mix.shell().info("   Suspicious Volume: #{yes_vol} Yes / #{no_vol} No (#{consensus_pct}% consensus)")

    if data.top_wallet_address do
      wallet_short = String.slice(data.top_wallet_address, 0..5) <> "..." <> String.slice(data.top_wallet_address, -5..-1)
      Mix.shell().info("   Top Wallet: #{wallet_short} (score: #{format_score(data.top_wallet_score)})")
    end

    if data.market_end_date do
      days = DateTime.diff(data.market_end_date, DateTime.utc_now(), :second) / 86400
      Mix.shell().info("   Ends in: #{Float.round(days, 1)} days")
    end

    if verbose do
      Mix.shell().info("   Category: #{data.market_category} | Condition: #{data.condition_id}")
    end

    Mix.shell().info("")
  end

  # Formatting helpers
  defp tier_badge("critical"), do: "[CRITICAL]"
  defp tier_badge("high"), do: "[HIGH]"
  defp tier_badge("medium"), do: "[MEDIUM]"
  defp tier_badge("low"), do: "[LOW]"
  defp tier_badge(_), do: "[???]"

  defp format_score(%Decimal{} = score), do: Decimal.round(score, 2) |> Decimal.to_string()
  defp format_score(score) when is_float(score), do: Float.round(score, 2) |> to_string()
  defp format_score(nil), do: "N/A"
  defp format_score(score), do: "#{score}"

  defp format_money(amount) when is_float(amount) do
    cond do
      amount >= 1_000_000 -> "$#{Float.round(amount / 1_000_000, 1)}M"
      amount >= 1_000 -> "$#{Float.round(amount / 1_000, 1)}K"
      true -> "$#{Float.round(amount, 0)}"
    end
  end
  defp format_money(_), do: "$0"

  defp truncate(nil, _), do: ""
  defp truncate(str, max) when byte_size(str) > max do
    String.slice(str, 0, max - 3) <> "..."
  end
  defp truncate(str, _), do: str

  defp decimal_to_float(nil), do: 0.0
  defp decimal_to_float(%Decimal{} = d), do: Decimal.to_float(d)
  defp decimal_to_float(n) when is_number(n), do: n * 1.0

  defp print_header(dry_run) do
    Mix.shell().info("")
    Mix.shell().info("╔══════════════════════════════════════════════════════════════╗")
    if dry_run do
      Mix.shell().info("║ FORWARD PREDICTION RECORDING (DRY RUN)                       ║")
    else
      Mix.shell().info("║ FORWARD PREDICTION RECORDING                                 ║")
    end
    Mix.shell().info("╚══════════════════════════════════════════════════════════════╝")
    Mix.shell().info("")
  end

  defp print_footer do
    Mix.shell().info("")
    Mix.shell().info("Next steps:")
    Mix.shell().info("  • Validate predictions: mix polymarket.validate_predictions")
    Mix.shell().info("  • View prediction stats: mix polymarket.validate_predictions --stats")
    Mix.shell().info("")
  end
end
