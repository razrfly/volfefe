defmodule VolfefeMachine.Polymarket.Validation do
  @moduledoc """
  Pilot validation and detection metrics for insider detection system.

  Provides:
  - Detection rate measurement against confirmed insiders
  - False negative analysis with pattern gap identification
  - Statistical metrics (precision, recall, F1 score)
  - High-volume market discovery for pilot testing

  ## Usage

      # Run full validation against confirmed insiders
      {:ok, results} = Validation.validate_detection()

      # Analyze false negatives
      {:ok, analysis} = Validation.analyze_false_negatives()

      # Find high-volume markets for pilot
      markets = Validation.find_pilot_markets(limit: 100)
  """

  import Ecto.Query
  require Logger

  alias VolfefeMachine.Repo
  alias VolfefeMachine.Polymarket.{
    ConfirmedInsider, Trade, TradeScore, InvestigationCandidate,
    Market
  }

  # Detection thresholds for classification
  @anomaly_threshold 0.5
  @probability_threshold 0.4

  # ============================================
  # Detection Validation
  # ============================================

  @doc """
  Validates detection system against all confirmed insiders.

  Returns comprehensive metrics:
  - Detection rate (how many insiders we flagged)
  - True positives, false negatives
  - Precision, recall, F1 score
  - Per-category breakdown

  ## Options

  - `:confidence_level` - Filter insiders by confidence (default: all)
  - `:anomaly_threshold` - Minimum anomaly score for detection (default: #{@anomaly_threshold})
  - `:probability_threshold` - Minimum probability for detection (default: #{@probability_threshold})

  ## Returns

      {:ok, %{
        total_insiders: 50,
        detected: 42,
        missed: 8,
        detection_rate: 0.84,
        by_category: %{politics: %{total: 23, detected: 20}, ...},
        by_confidence: %{confirmed: %{total: 30, detected: 28}, ...},
        false_negatives: [%{insider: insider, reason: "..."}, ...]
      }}
  """
  def validate_detection(opts \\ []) do
    confidence = Keyword.get(opts, :confidence_level)
    anomaly_thresh = Keyword.get(opts, :anomaly_threshold, @anomaly_threshold)
    prob_thresh = Keyword.get(opts, :probability_threshold, @probability_threshold)

    # Load all confirmed insiders
    insiders = load_confirmed_insiders(confidence)

    if Enum.empty?(insiders) do
      {:ok, %{
        total_insiders: 0,
        detected: 0,
        missed: 0,
        detection_rate: 0.0,
        by_category: %{},
        by_confidence: %{},
        false_negatives: [],
        thresholds: %{anomaly: anomaly_thresh, probability: prob_thresh}
      }}
    else
      # Check each insider for detection
      results = Enum.map(insiders, fn insider ->
        check_insider_detection(insider, anomaly_thresh, prob_thresh)
      end)

      # Aggregate results
      detected = Enum.filter(results, & &1.detected)
      missed = Enum.reject(results, & &1.detected)

      detection_rate = length(detected) / length(results)

      # Group by category
      by_category = group_by_category(results)

      # Group by confidence level
      by_confidence = group_by_confidence(results)

      # Analyze false negatives
      false_negatives = Enum.map(missed, fn result ->
        %{
          insider: result.insider,
          trade: result.trade,
          score: result.score,
          reason: diagnose_miss_reason(result)
        }
      end)

      {:ok, %{
        total_insiders: length(results),
        detected: length(detected),
        missed: length(missed),
        detection_rate: Float.round(detection_rate, 4),
        by_category: by_category,
        by_confidence: by_confidence,
        false_negatives: false_negatives,
        thresholds: %{anomaly: anomaly_thresh, probability: prob_thresh}
      }}
    end
  end

  @doc """
  Analyzes false negatives to identify pattern gaps.

  Returns grouped analysis of why insiders were missed:
  - No trade data
  - Low anomaly scores (which metrics failed?)
  - Missing pattern matches
  - Category-specific gaps

  ## Returns

      {:ok, %{
        total_missed: 8,
        reasons: %{
          no_trade_data: 2,
          low_anomaly_score: 4,
          low_probability: 2
        },
        metric_gaps: %{
          size_zscore: 3,      # 3 insiders had low size z-score
          timing_zscore: 1,
          ...
        },
        pattern_gaps: ["new_pattern_type", ...],
        recommendations: [...]
      }}
  """
  def analyze_false_negatives(opts \\ []) do
    case validate_detection(opts) do
      {:ok, %{false_negatives: false_negatives}} ->
        analyze_missed_insiders(false_negatives)

      error ->
        error
    end
  end

  @doc """
  Calculates precision, recall, and F1 score.

  Precision = TP / (TP + FP)  - Of flagged candidates, how many are real?
  Recall = TP / (TP + FN)     - Of real insiders, how many did we flag?
  F1 = 2 * (P * R) / (P + R)  - Harmonic mean

  ## Options

  - `:anomaly_threshold` - Minimum anomaly score for detection
  - `:probability_threshold` - Minimum probability for detection

  ## Returns

      {:ok, %{
        true_positives: 42,
        false_positives: 5,
        false_negatives: 8,
        precision: 0.89,
        recall: 0.84,
        f1_score: 0.86
      }}
  """
  def calculate_metrics(opts \\ []) do
    anomaly_thresh = Keyword.get(opts, :anomaly_threshold, @anomaly_threshold)
    prob_thresh = Keyword.get(opts, :probability_threshold, @probability_threshold)

    # True positives: confirmed insiders we detected
    confirmed_wallets = get_confirmed_wallet_condition_pairs()

    true_positives =
      from(ic in InvestigationCandidate,
        where: ic.anomaly_score >= ^Decimal.new("#{anomaly_thresh}"),
        where: ic.insider_probability >= ^Decimal.new("#{prob_thresh}"),
        select: {ic.wallet_address, ic.condition_id}
      )
      |> Repo.all()
      |> Enum.filter(fn {wallet, condition} ->
        MapSet.member?(confirmed_wallets, {wallet, condition})
      end)
      |> length()

    # False positives: candidates we flagged that aren't confirmed insiders
    total_flagged =
      from(ic in InvestigationCandidate,
        where: ic.anomaly_score >= ^Decimal.new("#{anomaly_thresh}"),
        where: ic.insider_probability >= ^Decimal.new("#{prob_thresh}")
      )
      |> Repo.aggregate(:count)

    false_positives = total_flagged - true_positives

    # False negatives: confirmed insiders we missed
    case validate_detection(opts) do
      {:ok, %{missed: false_negatives_count}} ->
        precision = safe_divide(true_positives, true_positives + false_positives)
        recall = safe_divide(true_positives, true_positives + false_negatives_count)
        f1 = safe_f1(precision, recall)

        {:ok, %{
          true_positives: true_positives,
          false_positives: false_positives,
          false_negatives: false_negatives_count,
          precision: precision,
          recall: recall,
          f1_score: f1,
          thresholds: %{anomaly: anomaly_thresh, probability: prob_thresh}
        }}

      error ->
        error
    end
  end

  # ============================================
  # High-Volume Market Discovery
  # ============================================

  @doc """
  Finds high-volume resolved markets for pilot testing.

  These are ideal for pilot because:
  - Resolved = we know the outcome (can verify correct trades)
  - High volume = more trades to analyze
  - More likely to have insider activity

  ## Options

  - `:limit` - Maximum markets to return (default: 100)
  - `:min_volume` - Minimum volume in USD (default: 100,000)
  - `:category` - Filter by category

  ## Returns

  List of markets sorted by volume with trade counts and resolution info.
  """
  def find_pilot_markets(opts \\ []) do
    limit = Keyword.get(opts, :limit, 100)
    min_volume = Keyword.get(opts, :min_volume, 100_000)
    category = Keyword.get(opts, :category)

    query =
      from(m in Market,
        where: not is_nil(m.resolved_outcome),
        where: m.volume >= ^Decimal.new("#{min_volume}"),
        order_by: [desc: m.volume],
        limit: ^limit
      )

    query = if category, do: from(m in query, where: m.category == ^category), else: query

    markets = Repo.all(query)

    # Enrich with trade counts and candidate info
    Enum.map(markets, fn market ->
      trade_count = count_trades_for_market(market.id)
      candidate_count = count_candidates_for_market(market.id)
      has_insider_data = has_confirmed_insider_for_market?(market.condition_id)

      %{
        market: market,
        trade_count: trade_count,
        candidate_count: candidate_count,
        has_insider_data: has_insider_data,
        score: calculate_pilot_priority(market, trade_count, candidate_count)
      }
    end)
    |> Enum.sort_by(& &1.score, :desc)
  end

  @doc """
  Gets category coverage statistics.

  Shows how many confirmed insiders and trades we have per category.
  """
  def category_coverage do
    # Insiders by category
    insiders = Repo.all(ConfirmedInsider)

    insider_categories =
      Enum.reduce(insiders, %{}, fn insider, acc ->
        category = get_insider_category(insider)
        Map.update(acc, category, 1, &(&1 + 1))
      end)

    # Trades by category
    trade_categories =
      from(t in Trade,
        join: m in Market, on: t.market_id == m.id,
        group_by: m.category,
        select: {m.category, count(t.id)}
      )
      |> Repo.all()
      |> Map.new()

    # Candidates by category
    candidate_categories =
      from(ic in InvestigationCandidate,
        join: m in Market, on: ic.market_id == m.id,
        group_by: m.category,
        select: {m.category, count(ic.id)}
      )
      |> Repo.all()
      |> Map.new()

    # Combine into coverage report
    all_categories = [:politics, :corporate, :legal, :crypto, :sports, :entertainment, :science, :other]

    coverage =
      Enum.map(all_categories, fn cat ->
        cat_str = to_string(cat)
        {cat, %{
          insiders: Map.get(insider_categories, cat_str, 0),
          trades: Map.get(trade_categories, cat, 0),
          candidates: Map.get(candidate_categories, cat, 0)
        }}
      end)
      |> Map.new()

    %{
      by_category: coverage,
      total_insiders: length(insiders),
      total_trades: Repo.aggregate(Trade, :count),
      total_candidates: Repo.aggregate(InvestigationCandidate, :count)
    }
  end

  # ============================================
  # Threshold Optimization
  # ============================================

  @doc """
  Tests multiple threshold combinations to find optimal settings.

  Runs validation at different threshold levels and reports metrics.

  ## Options

  - `:anomaly_range` - List of anomaly thresholds to test (default: [0.3, 0.4, 0.5, 0.6, 0.7])
  - `:probability_range` - List of probability thresholds (default: [0.3, 0.4, 0.5, 0.6])

  ## Returns

      {:ok, [
        %{anomaly: 0.5, probability: 0.4, precision: 0.89, recall: 0.84, f1: 0.86},
        ...
      ]}
  """
  def optimize_thresholds(opts \\ []) do
    anomaly_range = Keyword.get(opts, :anomaly_range, [0.3, 0.4, 0.5, 0.6, 0.7])
    probability_range = Keyword.get(opts, :probability_range, [0.3, 0.4, 0.5, 0.6])

    results =
      for anomaly <- anomaly_range, prob <- probability_range do
        case calculate_metrics(anomaly_threshold: anomaly, probability_threshold: prob) do
          {:ok, metrics} ->
            %{
              anomaly_threshold: anomaly,
              probability_threshold: prob,
              true_positives: metrics.true_positives,
              false_positives: metrics.false_positives,
              false_negatives: metrics.false_negatives,
              precision: metrics.precision,
              recall: metrics.recall,
              f1_score: metrics.f1_score
            }

          _ ->
            nil
        end
      end
      |> Enum.reject(&is_nil/1)
      |> Enum.sort_by(& &1.f1_score, :desc)

    {:ok, results}
  end

  # ============================================
  # Private Functions
  # ============================================

  defp load_confirmed_insiders(nil) do
    Repo.all(from(ci in ConfirmedInsider, order_by: [desc: ci.confirmed_at]))
  end

  defp load_confirmed_insiders(confidence) do
    Repo.all(from(ci in ConfirmedInsider,
      where: ci.confidence_level == ^confidence,
      order_by: [desc: ci.confirmed_at]
    ))
  end

  defp check_insider_detection(insider, anomaly_thresh, prob_thresh) do
    # Find the trade for this insider
    trade = find_insider_trade(insider)

    # Check if we have a score for this trade
    score = if trade, do: get_trade_score(trade.id), else: nil

    # Check if we flagged this as a candidate
    candidate = find_candidate_for_insider(insider)

    # Determine if we detected this insider
    detected =
      cond do
        # Flagged as candidate with sufficient scores
        candidate && score &&
          ensure_float(score.anomaly_score) >= anomaly_thresh &&
          ensure_float(score.insider_probability) >= prob_thresh ->
          true

        # Has high anomaly score even if not promoted to candidate
        score &&
          ensure_float(score.anomaly_score) >= anomaly_thresh &&
          ensure_float(score.insider_probability) >= prob_thresh ->
          true

        true ->
          false
      end

    %{
      insider: insider,
      trade: trade,
      score: score,
      candidate: candidate,
      detected: detected,
      category: get_insider_category(insider)
    }
  end

  defp find_insider_trade(%ConfirmedInsider{trade_id: trade_id}) when not is_nil(trade_id) do
    Repo.get(Trade, trade_id)
  end

  defp find_insider_trade(%ConfirmedInsider{transaction_hash: hash}) when not is_nil(hash) do
    Repo.get_by(Trade, transaction_hash: hash)
  end

  defp find_insider_trade(%ConfirmedInsider{wallet_address: wallet, condition_id: condition})
       when not is_nil(wallet) and not is_nil(condition) do
    # Find the most likely trade for this wallet/market combo
    from(t in Trade,
      where: t.wallet_address == ^wallet and t.condition_id == ^condition,
      order_by: [desc: t.size],
      limit: 1
    )
    |> Repo.one()
  end

  defp find_insider_trade(_), do: nil

  defp get_trade_score(trade_id) do
    Repo.get_by(TradeScore, trade_id: trade_id)
  end

  # Handle nil condition_id - match by wallet only
  defp find_candidate_for_insider(%ConfirmedInsider{wallet_address: wallet, condition_id: nil}) do
    from(ic in InvestigationCandidate,
      where: ic.wallet_address == ^wallet,
      limit: 1
    )
    |> Repo.one()
  end

  defp find_candidate_for_insider(%ConfirmedInsider{wallet_address: wallet, condition_id: condition}) do
    from(ic in InvestigationCandidate,
      where: ic.wallet_address == ^wallet,
      where: ic.condition_id == ^condition,
      limit: 1
    )
    |> Repo.one()
  end

  defp get_insider_category(%ConfirmedInsider{condition_id: condition_id}) when not is_nil(condition_id) do
    case Repo.get_by(Market, condition_id: condition_id) do
      %Market{category: category} -> to_string(category)
      nil -> "unknown"
    end
  end

  defp get_insider_category(_), do: "unknown"

  defp diagnose_miss_reason(%{trade: nil}) do
    "No trade data in system"
  end

  defp diagnose_miss_reason(%{score: nil}) do
    "Trade not scored"
  end

  defp diagnose_miss_reason(%{score: score}) do
    anomaly = ensure_float(score.anomaly_score)
    prob = ensure_float(score.insider_probability)

    cond do
      anomaly < @anomaly_threshold and prob < @probability_threshold ->
        low_metrics = identify_low_metrics(score)
        "Low anomaly (#{Float.round(anomaly, 2)}) and probability (#{Float.round(prob, 2)}). Weak signals: #{Enum.join(low_metrics, ", ")}"

      anomaly < @anomaly_threshold ->
        low_metrics = identify_low_metrics(score)
        "Low anomaly score (#{Float.round(anomaly, 2)}). Weak signals: #{Enum.join(low_metrics, ", ")}"

      prob < @probability_threshold ->
        "Low probability (#{Float.round(prob, 2)}) despite anomaly (#{Float.round(anomaly, 2)})"

      true ->
        "Unknown - should have been detected"
    end
  end

  defp identify_low_metrics(%TradeScore{} = score) do
    metrics = [
      {:size, score.size_zscore},
      {:timing, score.timing_zscore},
      {:wallet_age, score.wallet_age_zscore},
      {:wallet_activity, score.wallet_activity_zscore},
      {:price_extremity, score.price_extremity_zscore},
      {:position_concentration, score.position_concentration_zscore}
    ]

    metrics
    |> Enum.filter(fn {_name, zscore} ->
      abs(ensure_float(zscore)) < 1.5
    end)
    |> Enum.map(fn {name, zscore} ->
      "#{name}=#{Float.round(ensure_float(zscore), 2)}"
    end)
  end

  defp group_by_category(results) do
    results
    |> Enum.group_by(& &1.category)
    |> Enum.map(fn {category, items} ->
      detected = Enum.count(items, & &1.detected)
      {category, %{
        total: length(items),
        detected: detected,
        missed: length(items) - detected,
        detection_rate: safe_divide(detected, length(items))
      }}
    end)
    |> Map.new()
  end

  defp group_by_confidence(results) do
    results
    |> Enum.group_by(& &1.insider.confidence_level)
    |> Enum.map(fn {level, items} ->
      detected = Enum.count(items, & &1.detected)
      {level, %{
        total: length(items),
        detected: detected,
        missed: length(items) - detected,
        detection_rate: safe_divide(detected, length(items))
      }}
    end)
    |> Map.new()
  end

  defp analyze_missed_insiders(false_negatives) do
    # Group by reason type
    reasons =
      Enum.reduce(false_negatives, %{no_trade_data: 0, low_anomaly_score: 0, trade_not_scored: 0, low_probability: 0}, fn fn_item, acc ->
        reason = fn_item.reason
        cond do
          String.contains?(reason, "No trade data") ->
            Map.update!(acc, :no_trade_data, &(&1 + 1))

          String.contains?(reason, "not scored") ->
            Map.update!(acc, :trade_not_scored, &(&1 + 1))

          String.contains?(reason, "Low anomaly") ->
            Map.update!(acc, :low_anomaly_score, &(&1 + 1))

          String.contains?(reason, "Low probability") ->
            Map.update!(acc, :low_probability, &(&1 + 1))

          true ->
            acc
        end
      end)

    # Identify which metrics are frequently low
    metric_gaps =
      false_negatives
      |> Enum.filter(& &1.score)
      |> Enum.flat_map(fn fn_item ->
        identify_low_metrics(fn_item.score)
        |> Enum.map(fn metric_str ->
          [name | _] = String.split(metric_str, "=")
          name
        end)
      end)
      |> Enum.frequencies()

    # Generate recommendations
    recommendations = generate_recommendations(reasons, metric_gaps)

    {:ok, %{
      total_missed: length(false_negatives),
      reasons: reasons,
      metric_gaps: metric_gaps,
      recommendations: recommendations,
      details: false_negatives
    }}
  end

  defp generate_recommendations(reasons, metric_gaps) do
    recommendations = []

    recommendations =
      if reasons.no_trade_data > 0 do
        ["Ingest more historical trades: mix polymarket.ingest --days 90" | recommendations]
      else
        recommendations
      end

    recommendations =
      if reasons.trade_not_scored > 0 do
        ["Re-score trades: mix polymarket.rescore --all" | recommendations]
      else
        recommendations
      end

    recommendations =
      if Map.get(metric_gaps, "size", 0) >= 2 do
        ["Consider lowering size_zscore threshold - insiders using smaller positions" | recommendations]
      else
        recommendations
      end

    recommendations =
      if Map.get(metric_gaps, "timing", 0) >= 2 do
        ["Consider lowering timing_zscore threshold - insiders trading earlier" | recommendations]
      else
        recommendations
      end

    recommendations =
      if Map.get(metric_gaps, "wallet_age", 0) >= 2 do
        ["Insiders using established wallets - consider other signals" | recommendations]
      else
        recommendations
      end

    Enum.reverse(recommendations)
  end

  defp get_confirmed_wallet_condition_pairs do
    from(ci in ConfirmedInsider,
      select: {ci.wallet_address, ci.condition_id}
    )
    |> Repo.all()
    |> MapSet.new()
  end

  defp count_trades_for_market(market_id) do
    from(t in Trade, where: t.market_id == ^market_id)
    |> Repo.aggregate(:count)
  end

  defp count_candidates_for_market(market_id) do
    from(ic in InvestigationCandidate, where: ic.market_id == ^market_id)
    |> Repo.aggregate(:count)
  end

  defp has_confirmed_insider_for_market?(condition_id) do
    from(ci in ConfirmedInsider, where: ci.condition_id == ^condition_id)
    |> Repo.exists?()
  end

  defp calculate_pilot_priority(market, trade_count, candidate_count) do
    # Higher volume = higher priority
    volume_score = min(ensure_float(market.volume) / 1_000_000, 10)

    # More trades = more to analyze
    trade_score = min(trade_count / 1000, 5)

    # Existing candidates = already suspicious
    candidate_score = min(candidate_count * 2, 10)

    volume_score + trade_score + candidate_score
  end

  defp ensure_float(%Decimal{} = d), do: Decimal.to_float(d)
  defp ensure_float(n) when is_float(n), do: n
  defp ensure_float(n) when is_integer(n), do: n * 1.0
  defp ensure_float(nil), do: 0.0

  defp safe_divide(_, 0), do: 0.0
  defp safe_divide(num, denom), do: Float.round(num / denom, 4)

  defp safe_f1(precision, _) when precision == 0.0, do: 0.0
  defp safe_f1(_, recall) when recall == 0.0, do: 0.0
  defp safe_f1(precision, recall) do
    Float.round(2 * precision * recall / (precision + recall), 4)
  end

  # ============================================
  # Batch Pilot Discovery
  # ============================================

  @doc """
  Runs batch discovery on high-volume pilot markets.

  Ingests trades and runs discovery for each market in the pilot list.

  ## Options

  - `:limit` - Number of markets to process (default: 10)
  - `:min_volume` - Minimum market volume (default: 100,000)
  - `:anomaly_threshold` - Anomaly threshold for discovery (default: 0.5)
  - `:probability_threshold` - Probability threshold (default: 0.4)
  - `:skip_ingested` - Skip markets that already have trades (default: true)

  ## Returns

      {:ok, %{
        markets_processed: 10,
        trades_ingested: 5234,
        candidates_generated: 45,
        markets: [%{market: market, trades: 523, candidates: 5}, ...]
      }}
  """
  def run_batch_pilot(opts \\ []) do
    limit = Keyword.get(opts, :limit, 10)
    min_volume = Keyword.get(opts, :min_volume, 100_000)
    skip_ingested = Keyword.get(opts, :skip_ingested, true)
    anomaly_thresh = Keyword.get(opts, :anomaly_threshold, 0.5)
    prob_thresh = Keyword.get(opts, :probability_threshold, 0.4)

    # Get pilot markets
    pilot_markets = find_pilot_markets(limit: limit * 2, min_volume: min_volume)

    # Filter to markets needing processing
    markets_to_process =
      pilot_markets
      |> Enum.filter(fn m ->
        not skip_ingested or m.trade_count == 0
      end)
      |> Enum.take(limit)

    Logger.info("Processing #{length(markets_to_process)} pilot markets")

    # Process each market
    results =
      Enum.map(markets_to_process, fn pilot_market ->
        market = pilot_market.market
        Logger.info("Processing market: #{market.condition_id}")

        # Ingest trades if needed
        {trades_ingested, ingest_error} =
          if pilot_market.trade_count == 0 do
            case VolfefeMachine.Polymarket.ingest_market_trades(market.condition_id) do
              {:ok, stats} -> {stats.inserted + stats.updated, nil}
              {:error, reason} -> {0, reason}
            end
          else
            {0, nil}
          end

        # Run discovery (quick)
        candidates_generated =
          if is_nil(ingest_error) do
            run_market_discovery(market.id, anomaly_thresh, prob_thresh)
          else
            0
          end

        %{
          market: market,
          trades_ingested: trades_ingested,
          candidates_generated: candidates_generated,
          error: ingest_error,
          priority_score: pilot_market.score
        }
      end)

    # Aggregate stats
    total_trades = Enum.sum(Enum.map(results, & &1.trades_ingested))
    total_candidates = Enum.sum(Enum.map(results, & &1.candidates_generated))
    errors = Enum.count(results, & not is_nil(&1.error))

    {:ok, %{
      markets_processed: length(results),
      trades_ingested: total_trades,
      candidates_generated: total_candidates,
      errors: errors,
      markets: results
    }}
  end

  defp run_market_discovery(market_id, anomaly_thresh, prob_thresh) do
    # Get trades for this market that are scored
    query =
      from(ts in TradeScore,
        join: t in Trade, on: ts.trade_id == t.id,
        where: t.market_id == ^market_id,
        where: ts.anomaly_score >= ^Decimal.new("#{anomaly_thresh}"),
        where: ts.insider_probability >= ^Decimal.new("#{prob_thresh}")
      )

    Repo.aggregate(query, :count)
  end

  @doc """
  Gets a pilot progress report.

  Shows overall status of pilot testing campaign.
  """
  def pilot_progress do
    # Validation status
    validation_result =
      case validate_detection() do
        {:ok, results} -> results
        _ -> %{total_insiders: 0, detected: 0, detection_rate: 0.0}
      end

    # Metrics
    metrics_result =
      case calculate_metrics() do
        {:ok, metrics} -> metrics
        _ -> %{precision: 0.0, recall: 0.0, f1_score: 0.0}
      end

    # Coverage
    coverage = category_coverage()

    # Pilot markets status
    pilot_markets = find_pilot_markets(limit: 100)
    markets_with_data = Enum.count(pilot_markets, & &1.trade_count > 0)
    markets_with_candidates = Enum.count(pilot_markets, & &1.candidate_count > 0)

    %{
      validation: %{
        insiders_total: validation_result.total_insiders,
        insiders_detected: validation_result.detected,
        detection_rate: validation_result.detection_rate
      },
      metrics: %{
        precision: metrics_result.precision,
        recall: metrics_result.recall,
        f1_score: metrics_result.f1_score
      },
      coverage: %{
        total_insiders: coverage.total_insiders,
        total_trades: coverage.total_trades,
        total_candidates: coverage.total_candidates,
        by_category: coverage.by_category
      },
      pilot_markets: %{
        total: length(pilot_markets),
        with_trade_data: markets_with_data,
        with_candidates: markets_with_candidates,
        pending: length(pilot_markets) - markets_with_data
      },
      status: determine_pilot_status(validation_result, metrics_result),
      next_actions: suggest_next_actions(validation_result, metrics_result, pilot_markets)
    }
  end

  defp determine_pilot_status(validation, metrics) do
    cond do
      validation.total_insiders < 10 ->
        :need_more_insiders

      validation.detection_rate < 0.5 ->
        :detection_poor

      metrics.f1_score < 0.7 ->
        :metrics_below_target

      metrics.f1_score >= 0.85 ->
        :ready_for_production

      true ->
        :pilot_in_progress
    end
  end

  defp suggest_next_actions(validation, metrics, pilot_markets) do
    actions = []

    actions =
      if validation.total_insiders < 50 do
        ["Confirm more insiders from candidate queue" | actions]
      else
        actions
      end

    actions =
      if validation.detection_rate < 0.8 do
        ["Review false negatives: mix polymarket.pilot --analyze-misses" | actions]
      else
        actions
      end

    pending_markets = Enum.count(pilot_markets, & &1.trade_count == 0)
    actions =
      if pending_markets > 10 do
        ["Ingest pilot markets: mix polymarket.pilot --batch" | actions]
      else
        actions
      end

    actions =
      if metrics.f1_score < 0.85 do
        ["Optimize thresholds: mix polymarket.pilot --optimize" | actions]
      else
        actions
      end

    Enum.reverse(actions)
  end
end
