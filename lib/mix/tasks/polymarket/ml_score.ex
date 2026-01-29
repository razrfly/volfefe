defmodule Mix.Tasks.Polymarket.MlScore do
  @moduledoc """
  Run ML scoring pipeline on trade scores.

  Computes ML anomaly scores using Isolation Forest and combines with
  rule-based scores to produce ensemble scores.

  ## Usage

      # Run ML scoring on all scored trades
      mix polymarket.ml_score

      # Score with limit (for testing)
      mix polymarket.ml_score --limit 1000

      # Score only trades without ML scores
      mix polymarket.ml_score --unscored

      # Score specific market by condition_id
      mix polymarket.ml_score --condition-id 0x14a3dfeb...

  ## Options

      --limit         Maximum trades to score
      --batch         Batch size for ML processing (default: 1000)
      --unscored      Only score trades missing ml_anomaly_score
      --condition-id  Score trades for specific market
      --dry-run       Show what would be scored without updating

  ## Pipeline

  1. Load trade scores with related trade/wallet data
  2. Compute 22 ML features using FeatureEngineer
  3. Run Isolation Forest anomaly detection
  4. Calculate ensemble score (rules + ML + patterns)
  5. Update trade_scores with ml_anomaly_score, ml_confidence, ensemble_score
  """

  use Mix.Task
  require Logger
  import Ecto.Query

  alias VolfefeMachine.Repo
  alias VolfefeMachine.Polymarket.{Trade, TradeScore, Wallet}
  alias VolfefeMachine.Intelligence.{AnomalyDetector, EnsembleScorer, FeatureEngineer}

  @shortdoc "Run ML scoring pipeline on trade scores"

  @impl Mix.Task
  def run(args) do
    Mix.Task.run("app.start")

    {opts, _, _} = OptionParser.parse(args,
      switches: [
        limit: :integer,
        batch: :integer,
        unscored: :boolean,
        condition_id: :string,
        dry_run: :boolean
      ],
      aliases: [l: :limit, b: :batch, u: :unscored, c: :condition_id, d: :dry_run]
    )

    print_header()

    batch_size = opts[:batch] || 1000
    limit = opts[:limit]
    dry_run = opts[:dry_run] || false

    # Build query based on options
    query = build_query(opts)

    # Count total
    total = Repo.aggregate(query, :count)

    if total == 0 do
      Mix.shell().info("No trades to score.")
      return_early()
    else
      Mix.shell().info("Found #{format_number(total)} trades to ML score")
      Mix.shell().info("Batch size: #{batch_size}")
      if dry_run, do: Mix.shell().info("DRY RUN - no changes will be made")
      Mix.shell().info("")

      if dry_run do
        show_sample(query)
      else
        run_ml_pipeline(query, batch_size, limit)
      end
    end

    print_footer()
  end

  defp build_query(opts) do
    # Base query without select - for counting
    # Order by ts.id for deterministic offset pagination
    base = from(ts in TradeScore,
      join: t in Trade, on: t.id == ts.trade_id,
      left_join: w in Wallet, on: w.id == t.wallet_id,
      order_by: [asc: ts.id]
    )

    base
    |> maybe_filter_unscored(opts[:unscored])
    |> maybe_filter_condition_id(opts[:condition_id])
    |> maybe_limit(opts[:limit])
  end

  # Add select for data fetching
  defp with_select(query) do
    from([ts, t, w] in query,
      select: %{
        score: ts,
        trade: t,
        wallet: w
      }
    )
  end

  defp maybe_filter_unscored(query, true) do
    from([ts, t, w] in query, where: is_nil(ts.ml_anomaly_score))
  end
  defp maybe_filter_unscored(query, _), do: query

  defp maybe_filter_condition_id(query, nil), do: query
  defp maybe_filter_condition_id(query, condition_id) do
    from([ts, t, w] in query, where: t.condition_id == ^condition_id)
  end

  defp maybe_limit(query, nil), do: query
  defp maybe_limit(query, limit), do: from(q in query, limit: ^limit)

  defp show_sample(query) do
    sample = query |> with_select() |> limit(5) |> Repo.all()

    Mix.shell().info("Sample trades that would be scored:")
    Mix.shell().info("")

    for %{score: score, trade: trade} <- sample do
      Mix.shell().info("  Trade #{trade.id}: anomaly=#{score.anomaly_score}, condition=#{String.slice(trade.condition_id || "", 0..15)}...")
    end
  end

  defp run_ml_pipeline(query, batch_size, limit) do
    # Stream trades in batches
    start_time = System.monotonic_time(:millisecond)

    # Get total for progress
    total = min(Repo.aggregate(query, :count), limit || 999_999_999)
    num_batches = ceil(total / batch_size)

    Mix.shell().info("Processing #{num_batches} batches...")
    Mix.shell().info("")

    # Process in batches using offset
    result = process_batches(query, batch_size, total)

    elapsed = System.monotonic_time(:millisecond) - start_time

    Mix.shell().info("")
    Mix.shell().info("╔══════════════════════════════════════════════════════════════╗")
    Mix.shell().info("║ ML SCORING COMPLETE                                          ║")
    Mix.shell().info("╠══════════════════════════════════════════════════════════════╣")
    Mix.shell().info("║ Trades scored:    #{String.pad_leading(format_number(result.scored), 10)}                           ║")
    Mix.shell().info("║ Errors:           #{String.pad_leading(format_number(result.errors), 10)}                           ║")
    Mix.shell().info("║ Time elapsed:     #{String.pad_leading(format_duration(elapsed), 10)}                           ║")
    Mix.shell().info("║ Rate:             #{String.pad_leading("#{round(result.scored / max(elapsed/1000, 1))}/sec", 10)}                           ║")
    Mix.shell().info("╚══════════════════════════════════════════════════════════════╝")

    # Show score distribution
    show_score_distribution()
  end

  defp process_batches(query, batch_size, total) do
    num_batches = ceil(total / batch_size)

    0..(num_batches - 1)
    |> Enum.reduce(%{scored: 0, errors: 0}, fn batch_num, acc ->
      offset = batch_num * batch_size

      # Fetch batch with select for data
      batch_query = query |> with_select() |> offset(^offset) |> limit(^batch_size)
      batch = Repo.all(batch_query)

      if length(batch) > 0 do
        case score_batch(batch) do
          {:ok, batch_result} ->
            progress = round((batch_num + 1) / num_batches * 100)
            Mix.shell().info("  Batch #{batch_num + 1}/#{num_batches} (#{progress}%): #{batch_result.scored} scored, #{batch_result.errors} errors")

            %{
              scored: acc.scored + batch_result.scored,
              errors: acc.errors + batch_result.errors
            }

          {:error, reason} ->
            Mix.shell().info("  Batch #{batch_num + 1} FAILED: #{inspect(reason)}")
            %{acc | errors: acc.errors + length(batch)}
        end
      else
        acc
      end
    end)
  end

  defp score_batch(batch) do
    # Extract features for all trades in batch
    features = Enum.map(batch, fn %{score: score, trade: trade, wallet: wallet} ->
      # Get extended features
      extended = FeatureEngineer.compute_features(trade, wallet)

      # Build full 22-feature vector (all values must be floats for numpy/sklearn)
      [
        ensure_float(score.size_zscore),
        ensure_float(score.timing_zscore),
        ensure_float(score.wallet_age_zscore),
        ensure_float(score.wallet_activity_zscore),
        ensure_float(score.price_extremity_zscore),
        ensure_float(score.position_concentration_zscore),
        ensure_float(score.funding_proximity_zscore),
        ensure_float(extended.raw_size_normalized),
        ensure_float(extended.raw_price),
        ensure_float(extended.raw_hours_before_resolution),
        ensure_float(extended.raw_wallet_age_days),
        ensure_float(extended.raw_wallet_trade_count),
        if(extended.is_buy, do: 1.0, else: 0.0),
        ensure_float(extended.outcome_index),
        ensure_float(extended.price_confidence),
        ensure_float(extended.wallet_win_rate),
        ensure_float(extended.wallet_volume_zscore),
        ensure_float(extended.wallet_unique_markets_normalized),
        ensure_float(extended.funding_amount_normalized),
        ensure_float(extended.trade_hour_sin),
        ensure_float(extended.trade_hour_cos),
        ensure_float(extended.trade_day_sin),
        ensure_float(extended.trade_day_cos)
      ]
    end)

    # Run Isolation Forest on batch
    case AnomalyDetector.fit_predict(features) do
      {:ok, ml_result} ->
        # Update each trade score with ML results and ensemble score
        results = batch
        |> Enum.with_index()
        |> Enum.map(fn {%{score: score, trade: trade}, idx} ->
          ml_score = Enum.at(ml_result.anomaly_scores, idx, 0.0)
          ml_conf = Enum.at(ml_result.confidence, idx, 0.0)

          # Calculate trinity pattern FIRST (needed for ensemble boost)
          trinity = check_trinity_pattern(score)

          # Calculate ensemble score with trinity boost
          ensemble_input = %{
            anomaly_score: score.anomaly_score,
            ml_anomaly_score: ml_score,
            ml_confidence: ml_conf,
            highest_pattern_score: score.highest_pattern_score,
            was_correct: trade.was_correct,
            trinity_pattern: trinity
          }

          {:ok, ensemble} = EnsembleScorer.calculate(ensemble_input)

          # Update the score record
          update_trade_score(score, %{
            ml_anomaly_score: Decimal.from_float(ml_score),
            ml_confidence: Decimal.from_float(ml_conf),
            ensemble_score: Decimal.from_float(ensemble),
            trinity_pattern: trinity
          })
        end)

        scored = Enum.count(results, &match?({:ok, _}, &1))
        errors = Enum.count(results, &match?({:error, _}, &1))

        {:ok, %{scored: scored, errors: errors}}

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp update_trade_score(score, attrs) do
    score
    |> TradeScore.changeset(attrs)
    |> Repo.update()
  end

  defp check_trinity_pattern(score) do
    # Trinity pattern: all three core signals significant (|z| >= 2.0)
    size_z = abs(ensure_float(score.size_zscore))
    timing_z = abs(ensure_float(score.timing_zscore))
    wallet_z = abs(ensure_float(score.wallet_age_zscore))

    size_z >= 2.0 and timing_z >= 2.0 and wallet_z >= 2.0
  end

  defp show_score_distribution do
    Mix.shell().info("")
    Mix.shell().info("Score Distribution:")

    # Get distribution
    dist = Repo.all(from ts in TradeScore,
      where: not is_nil(ts.ensemble_score),
      select: %{
        critical: count(fragment("CASE WHEN ?::numeric > 0.9 THEN 1 END", ts.ensemble_score)),
        high: count(fragment("CASE WHEN ?::numeric > 0.7 AND ?::numeric <= 0.9 THEN 1 END", ts.ensemble_score, ts.ensemble_score)),
        medium: count(fragment("CASE WHEN ?::numeric > 0.5 AND ?::numeric <= 0.7 THEN 1 END", ts.ensemble_score, ts.ensemble_score)),
        low: count(fragment("CASE WHEN ?::numeric > 0.3 AND ?::numeric <= 0.5 THEN 1 END", ts.ensemble_score, ts.ensemble_score)),
        normal: count(fragment("CASE WHEN ?::numeric <= 0.3 THEN 1 END", ts.ensemble_score))
      }
    ) |> List.first()

    if dist do
      Mix.shell().info("  🚨 Critical (>0.9): #{format_number(dist.critical)}")
      Mix.shell().info("  🔴 High (>0.7):     #{format_number(dist.high)}")
      Mix.shell().info("  🟠 Medium (>0.5):   #{format_number(dist.medium)}")
      Mix.shell().info("  🟡 Low (>0.3):      #{format_number(dist.low)}")
      Mix.shell().info("  🟢 Normal (≤0.3):   #{format_number(dist.normal)}")
    end
  end

  defp ensure_float(nil), do: 0.0
  defp ensure_float(%Decimal{} = d), do: Decimal.to_float(d)
  defp ensure_float(n) when is_float(n), do: n
  defp ensure_float(n) when is_integer(n), do: n * 1.0

  defp print_header do
    Mix.shell().info("")
    Mix.shell().info("╔══════════════════════════════════════════════════════════════╗")
    Mix.shell().info("║ POLYMARKET ML SCORING PIPELINE                               ║")
    Mix.shell().info("╚══════════════════════════════════════════════════════════════╝")
    Mix.shell().info("")
  end

  defp print_footer do
    Mix.shell().info("")
    Mix.shell().info("Next steps:")
    Mix.shell().info("  • Run discovery: mix polymarket.discover --ml")
    Mix.shell().info("  • View top candidates by ensemble score")
    Mix.shell().info("")
  end

  defp return_early do
    Mix.shell().info("")
  end

  defp format_number(n) when is_integer(n) do
    n
    |> Integer.to_string()
    |> String.reverse()
    |> String.replace(~r/(\d{3})(?=\d)/, "\\1,")
    |> String.reverse()
  end
  defp format_number(n), do: "#{n}"

  defp format_duration(ms) when ms < 1000, do: "#{ms}ms"
  defp format_duration(ms) when ms < 60_000 do
    "#{Float.round(ms / 1000, 1)}s"
  end
  defp format_duration(ms) do
    minutes = div(ms, 60_000)
    seconds = rem(ms, 60_000) |> div(1000)
    "#{minutes}m #{seconds}s"
  end
end
