defmodule VolfefeMachine.Intelligence.EnsembleScorer do
  @moduledoc """
  Ensemble scoring combining rule-based and ML anomaly detection.

  Combines multiple signals for robust insider detection:

  ## Scoring Components (Phase 9.2 tuned)

  1. **Rule-Based Score** (anomaly_score): 45% weight
     - Weighted z-score combination with Trinity boost
     - Best discrimination (0-1 range), increased weight

  2. **ML Score** (ml_anomaly_score): 30% weight
     - Isolation Forest on 22-feature vector
     - Compressed range (~0.3-0.7), reduced weight

  3. **Pattern Score** (highest_pattern_score): 10% weight
     - Known insider behavior patterns
     - Reduced weight (base patterns match all trades)

  4. **Outcome Boost** (was_correct): 15% weight
     - Trades that correctly predicted outcome
     - Increased weight (important discriminator)

  ## Ensemble Formula

  ```
  ensemble_score = (
    rule_score * 0.45 +
    ml_score * 0.30 +
    pattern_score * 0.10 +
    correct_boost * 0.15
  )
  ```

  ## Confidence-Weighted Variant

  When ML confidence is available, weights adjust dynamically:
  - High ML confidence (>0.8): Increase ML weight to 0.35
  - Low ML confidence (<0.5): Decrease ML weight to 0.25

  ## Trinity Boost (Phase 9.3)

  When the rare "Trinity Pattern" is present (all 3 core z-scores >= 2.0),
  a synergy boost is applied to reward this exceptional alignment:

  - Trinity + correct + pattern >= 0.8: +0.12 boost
  - Trinity + correct: +0.08 boost
  - Trinity only: +0.05 boost

  This enables Critical tier (>0.9) for truly exceptional anomalies while
  maintaining rarity - only ~0.006% of trades have trinity pattern.
  """

  require Logger

  alias VolfefeMachine.Intelligence.AnomalyDetector

  # Base weights for ensemble (Phase 9.2 tuning)
  # Rule: increased to 0.45 (has best spread 0-1)
  # ML: reduced to 0.30 (compressed scores ~0.3-0.6)
  # Pattern: reduced to 0.10 (all trades match base patterns)
  # Outcome: increased to 0.15 (important discriminator when available)
  @rule_weight 0.45
  @ml_weight 0.30
  @pattern_weight 0.10
  @outcome_weight 0.15

  # Confidence thresholds for dynamic weighting
  @high_confidence 0.8
  @low_confidence 0.5

  # Trinity Boost values (Phase 9.3)
  # Applied when trinity_pattern is true (all 3 core z-scores >= 2.0)
  @trinity_boost_full 0.12      # Trinity + correct + high pattern
  @trinity_boost_correct 0.08  # Trinity + correct outcome
  @trinity_boost_base 0.05     # Trinity pattern alone
  @trinity_pattern_threshold 0.8  # Pattern score threshold for full boost

  @doc """
  Calculate ensemble score from all available signals.

  ## Parameters

  - `scores` - Map containing:
    - `:anomaly_score` - Rule-based anomaly score (0-1)
    - `:ml_anomaly_score` - ML anomaly score (0-1)
    - `:ml_confidence` - ML prediction confidence (0-1)
    - `:highest_pattern_score` - Pattern match score (0-1)
    - `:was_correct` - Whether trade was correct (boolean)
    - `:trinity_pattern` - Whether trinity pattern present (boolean, optional)

  ## Options

  - `:dynamic_weights` - Adjust weights based on ML confidence (default: true)
  - `:include_breakdown` - Return weight breakdown (default: false)

  ## Returns

  `{:ok, ensemble_score}` or `{:ok, %{score: score, breakdown: map}}`
  """
  def calculate(scores, opts \\ []) do
    dynamic_weights = Keyword.get(opts, :dynamic_weights, true)
    include_breakdown = Keyword.get(opts, :include_breakdown, false)

    # Extract scores with defaults
    rule_score = ensure_float(scores[:anomaly_score])
    ml_score = ensure_float(scores[:ml_anomaly_score])
    ml_confidence = ensure_float(scores[:ml_confidence])
    pattern_score = ensure_float(scores[:highest_pattern_score])
    was_correct = scores[:was_correct] == true
    trinity_pattern = scores[:trinity_pattern] == true

    # Calculate weights (possibly adjusted for ML confidence)
    weights = if dynamic_weights do
      calculate_dynamic_weights(ml_confidence)
    else
      %{rule: @rule_weight, ml: @ml_weight, pattern: @pattern_weight, outcome: @outcome_weight}
    end

    # Compute ensemble score
    correct_boost = if was_correct, do: 1.0, else: 0.0

    base_ensemble = (
      rule_score * weights.rule +
      ml_score * weights.ml +
      pattern_score * weights.pattern +
      correct_boost * weights.outcome
    )

    # Apply Trinity Boost (Phase 9.3)
    # Rewards rare alignment of all 3 core z-scores >= 2.0
    trinity_boost = calculate_trinity_boost(trinity_pattern, was_correct, pattern_score)

    # Cap at 1.0
    final_score = min(base_ensemble + trinity_boost, 1.0)

    if include_breakdown do
      breakdown = %{
        rule_contribution: Float.round(rule_score * weights.rule, 4),
        ml_contribution: Float.round(ml_score * weights.ml, 4),
        pattern_contribution: Float.round(pattern_score * weights.pattern, 4),
        outcome_contribution: Float.round(correct_boost * weights.outcome, 4),
        trinity_boost: Float.round(trinity_boost, 4),
        base_ensemble: Float.round(base_ensemble, 4),
        weights: weights,
        components: %{
          rule_score: Float.round(rule_score, 4),
          ml_score: Float.round(ml_score, 4),
          ml_confidence: Float.round(ml_confidence, 4),
          pattern_score: Float.round(pattern_score, 4),
          was_correct: was_correct,
          trinity_pattern: trinity_pattern
        }
      }
      {:ok, %{score: Float.round(final_score, 4), breakdown: breakdown}}
    else
      {:ok, Float.round(final_score, 4)}
    end
  end

  @doc """
  Calculate ensemble scores for multiple trade scores using batch ML prediction.

  More efficient than scoring one at a time when you have many trades.
  """
  def calculate_batch(trade_scores, opts \\ []) when is_list(trade_scores) do
    # Guard against empty input
    if trade_scores == [] do
      []
    else
      # Extract features for ML scoring
      features = Enum.map(trade_scores, &AnomalyDetector.extract_core_features/1)

      # Pass explicit feature names to ensure correct feature count/order for Python
      ml_opts = Keyword.put_new(opts, :feature_names, AnomalyDetector.core_feature_names())

      # Run batch ML prediction
      ml_results = case AnomalyDetector.fit_predict(features, ml_opts) do
        {:ok, result} -> result
        {:error, _} -> nil
      end

      # Combine ML results with existing scores
      trade_scores
      |> Enum.with_index()
      |> Enum.map(fn {score, idx} ->
        ml_score = if ml_results, do: Enum.at(ml_results.anomaly_scores, idx, 0.0), else: 0.0
        ml_conf = if ml_results, do: Enum.at(ml_results.confidence, idx, 0.0), else: 0.0

        scores = %{
          anomaly_score: score.anomaly_score,
          ml_anomaly_score: ml_score,
          ml_confidence: ml_conf,
          highest_pattern_score: score.highest_pattern_score,
          was_correct: get_was_correct(score)
        }

        {:ok, ensemble_score} = calculate(scores)

        %{
          trade_id: score.trade_id,
          ensemble_score: ensemble_score,
          ml_anomaly_score: ml_score,
          ml_confidence: ml_conf
        }
      end)
    end
  end

  @doc """
  Get tier classification based on ensemble score.

  Tiers help prioritize investigation:
  - :critical (>0.9): Immediate review required
  - :high (>0.7): High priority investigation
  - :medium (>0.5): Standard investigation
  - :low (>0.3): Worth monitoring
  - :normal (<=0.3): Normal trading behavior
  """
  def classify_tier(ensemble_score) do
    score = ensure_float(ensemble_score)

    cond do
      score > 0.9 -> :critical
      score > 0.7 -> :high
      score > 0.5 -> :medium
      score > 0.3 -> :low
      true -> :normal
    end
  end

  @doc """
  Get human-readable explanation for an ensemble score.
  """
  def explain(scores) when is_map(scores) do
    case calculate(scores, include_breakdown: true) do
      {:ok, %{score: score, breakdown: breakdown}} ->
        tier = classify_tier(score)

        explanation = %{
          ensemble_score: score,
          tier: tier,
          top_contributors: get_top_contributors(breakdown),
          interpretation: interpret_score(score, breakdown)
        }

        {:ok, explanation}

      error ->
        error
    end
  end

  # ============================================
  # Trinity Boost Calculation (Phase 9.3)
  # ============================================

  defp calculate_trinity_boost(false, _was_correct, _pattern_score), do: 0.0
  defp calculate_trinity_boost(true, was_correct, pattern_score) do
    cond do
      was_correct and pattern_score >= @trinity_pattern_threshold ->
        # Full boost: Trinity + correct + high pattern
        @trinity_boost_full

      was_correct ->
        # Medium boost: Trinity + correct outcome
        @trinity_boost_correct

      true ->
        # Base boost: Trinity pattern alone
        @trinity_boost_base
    end
  end

  # ============================================
  # Dynamic Weight Calculation
  # ============================================

  defp calculate_dynamic_weights(ml_confidence) do
    cond do
      ml_confidence >= @high_confidence ->
        # High ML confidence: increase ML weight (take from rule)
        ml_boost = 0.05
        %{
          rule: @rule_weight - ml_boost,
          ml: @ml_weight + ml_boost,
          pattern: @pattern_weight,
          outcome: @outcome_weight
        }

      ml_confidence < @low_confidence ->
        # Low ML confidence: decrease ML weight (give to rule)
        ml_reduction = 0.05
        %{
          rule: @rule_weight + ml_reduction,
          ml: @ml_weight - ml_reduction,
          pattern: @pattern_weight,
          outcome: @outcome_weight
        }

      true ->
        # Normal confidence: use base weights
        %{rule: @rule_weight, ml: @ml_weight, pattern: @pattern_weight, outcome: @outcome_weight}
    end
  end

  # ============================================
  # Helper Functions
  # ============================================

  defp get_top_contributors(breakdown) do
    [
      {:rule_based, breakdown.rule_contribution},
      {:ml_model, breakdown.ml_contribution},
      {:pattern_match, breakdown.pattern_contribution},
      {:correct_outcome, breakdown.outcome_contribution}
    ]
    |> Enum.sort_by(fn {_, v} -> v end, :desc)
    |> Enum.take(2)
    |> Enum.map(fn {name, value} -> %{factor: name, contribution: value} end)
  end

  defp interpret_score(score, breakdown) do
    components = breakdown.components

    cond do
      score > 0.9 ->
        "Critical anomaly detected. Multiple strong signals indicate potential insider activity."

      score > 0.7 and components.was_correct ->
        "High-risk trade that correctly predicted outcome with anomalous patterns."

      score > 0.7 ->
        "High-risk trade showing multiple anomaly indicators."

      score > 0.5 and components.ml_score > 0.7 ->
        "ML model detected unusual pattern not fully captured by rules."

      score > 0.5 ->
        "Moderate anomaly signals. Warrants further investigation."

      score > 0.3 ->
        "Slightly elevated anomaly indicators. Low priority."

      true ->
        "Normal trading behavior within expected parameters."
    end
  end

  defp get_was_correct(score) do
    # Handle both struct and map access
    cond do
      is_map(score) and Map.has_key?(score, :was_correct) -> score.was_correct
      is_map(score) and Map.has_key?(score, "was_correct") -> score["was_correct"]
      true -> nil
    end
  end

  defp ensure_float(nil), do: 0.0
  defp ensure_float(%Decimal{} = d), do: Decimal.to_float(d)
  defp ensure_float(n) when is_float(n), do: n
  defp ensure_float(n) when is_integer(n), do: n * 1.0
end
