defmodule VolfefeMachine.Polymarket.TradeScore do
  @moduledoc """
  Ecto schema for trade scores.

  Stores computed anomaly metrics for each trade:
  - Z-scores for each metric (how many stddevs from normal)
  - Composite anomaly score with Trinity Weighting
  - Insider probability estimate
  - Pattern matches

  ## Scoring Formula

  **Z-Score**: `(value - mean) / stddev`
  - |z| > 2.0 → Unusual (top 2.5%)
  - |z| > 2.5 → Very unusual (top 0.6%)
  - |z| > 3.0 → Extreme (top 0.1%)

  **Anomaly Score**: Weighted z-scores with Trinity Boost

  Base weights:
  - size_zscore: 25%
  - timing_zscore: 25%
  - wallet_age_zscore: 20%
  - position_concentration_zscore: 15%
  - wallet_activity_zscore: 8%
  - price_extremity_zscore: 4%
  - funding_proximity_zscore: 3%

  **Trinity Boost**: When all three core signals (size, timing, wallet_age) are
  significant (|z| >= 2.0), apply 1.25x multiplier. This captures the classic
  insider pattern: large trade + perfect timing + new/suspicious wallet.

  **Insider Probability**: Weighted combination
  ```
  probability = anomaly_score * 0.4 + pattern_score * 0.4 + correct_boost * 0.2
  ```
  """

  use Ecto.Schema
  import Ecto.Changeset

  schema "polymarket_trade_scores" do
    belongs_to :trade, VolfefeMachine.Polymarket.Trade

    field :transaction_hash, :string

    # === Core Z-Scores (Features 1-7) ===
    field :size_zscore, :decimal
    field :timing_zscore, :decimal
    field :wallet_age_zscore, :decimal
    field :wallet_activity_zscore, :decimal
    field :price_extremity_zscore, :decimal
    field :position_concentration_zscore, :decimal
    field :funding_proximity_zscore, :decimal

    # === Extended Features (8-15) ===
    # Raw normalized values
    field :raw_size_normalized, :decimal
    field :raw_price, :decimal
    field :raw_hours_before_resolution, :decimal
    field :raw_wallet_age_days, :integer
    field :raw_wallet_trade_count, :integer

    # Binary/categorical features
    field :is_buy, :boolean
    field :outcome_index, :integer

    # Derived confidence
    field :price_confidence, :decimal

    # === Wallet-Level Features (16-19) ===
    field :wallet_win_rate, :decimal
    field :wallet_volume_zscore, :decimal
    field :wallet_unique_markets_normalized, :decimal
    field :funding_amount_normalized, :decimal

    # === Contextual Features (20-22) ===
    field :trade_hour_sin, :decimal
    field :trade_hour_cos, :decimal
    field :trade_day_sin, :decimal
    field :trade_day_cos, :decimal

    # === Scores ===
    # Rule-based combined scores
    field :anomaly_score, :decimal
    field :insider_probability, :decimal

    # ML model outputs
    field :ml_anomaly_score, :decimal
    field :ml_confidence, :decimal

    # Ensemble (rules + ML)
    field :ensemble_score, :decimal

    # Trinity pattern flag
    field :trinity_pattern, :boolean, default: false

    # Pattern matches
    field :matched_patterns, :map
    field :highest_pattern_score, :decimal

    # Discovery ranking
    field :discovery_rank, :integer

    field :scored_at, :utc_datetime

    timestamps(type: :utc_datetime)
  end

  @optional_fields ~w(
    trade_id transaction_hash
    size_zscore timing_zscore wallet_age_zscore
    wallet_activity_zscore price_extremity_zscore
    position_concentration_zscore funding_proximity_zscore
    raw_size_normalized raw_price raw_hours_before_resolution
    raw_wallet_age_days raw_wallet_trade_count
    is_buy outcome_index price_confidence
    wallet_win_rate wallet_volume_zscore
    wallet_unique_markets_normalized funding_amount_normalized
    trade_hour_sin trade_hour_cos trade_day_sin trade_day_cos
    anomaly_score insider_probability
    ml_anomaly_score ml_confidence ensemble_score trinity_pattern
    matched_patterns highest_pattern_score
    discovery_rank scored_at
  )a

  def changeset(score, attrs) do
    score
    |> cast(attrs, @optional_fields)
    |> unique_constraint(:trade_id)
  end

  # Trinity signal threshold - z-score must be >= this to count as "significant"
  @trinity_threshold 2.0
  # Boost multiplier when all three trinity signals fire
  @trinity_boost 1.25

  # Weights for each z-score (must sum to 1.0)
  @zscore_weights %{
    size_zscore: 0.25,
    timing_zscore: 0.25,
    wallet_age_zscore: 0.20,
    position_concentration_zscore: 0.15,
    wallet_activity_zscore: 0.08,
    price_extremity_zscore: 0.04,
    funding_proximity_zscore: 0.03
  }

  @doc """
  Calculates composite anomaly score from z-scores using Trinity Weighting.

  Uses weighted z-scores with a boost when all three core signals
  (size, timing, wallet_age) are significant.

  ## Parameters
  - `zscores` - Either a list of z-scores (legacy) or a map with named z-scores

  ## Returns
  Decimal between 0 and 1, where 1.0 = extreme anomaly
  """
  def calculate_anomaly_score(zscores) when is_list(zscores) do
    # Legacy list-based scoring (for backwards compatibility)
    valid_zscores = Enum.reject(zscores, &is_nil/1)

    if Enum.empty?(valid_zscores) do
      Decimal.new("0.0")
    else
      # RMS of z-scores, normalized
      sum_squares =
        valid_zscores
        |> Enum.map(fn z ->
          z_float = ensure_float(z)
          z_float * z_float
        end)
        |> Enum.sum()

      rms = :math.sqrt(sum_squares / length(valid_zscores))

      # Normalize by 3.0 (3 sigma = extreme) and cap at 1.0
      normalized = min(rms / 3.0, 1.0)
      Decimal.from_float(Float.round(normalized, 4))
    end
  end

  def calculate_anomaly_score(zscores) when is_map(zscores) do
    # New weighted scoring with Trinity boost
    weighted_sum =
      @zscore_weights
      |> Enum.reduce(0.0, fn {metric, weight}, acc ->
        zscore = Map.get(zscores, metric) || Map.get(zscores, to_string(metric))
        z = abs(ensure_float(zscore))
        # Normalize each z-score to 0-1 range (3.0 = 1.0)
        normalized_z = min(z / 3.0, 1.0)
        acc + normalized_z * weight
      end)

    # Check for Trinity boost
    trinity_boost = calculate_trinity_boost(zscores)

    # Apply boost and cap at 1.0
    final_score = min(weighted_sum * trinity_boost, 1.0)
    Decimal.from_float(Float.round(final_score, 4))
  end

  @doc """
  Calculates the Trinity boost multiplier.

  Returns #{@trinity_boost}x when all three core signals (size, timing, wallet_age)
  are significant (|z| >= #{@trinity_threshold}).

  This captures the classic insider pattern:
  - Large trade (size)
  - Perfect timing (close to resolution)
  - Suspicious wallet (new or unusual activity)
  """
  def calculate_trinity_boost(zscores) when is_map(zscores) do
    trinity_signals = [:size_zscore, :timing_zscore, :wallet_age_zscore]

    all_significant? =
      Enum.all?(trinity_signals, fn metric ->
        zscore = Map.get(zscores, metric) || Map.get(zscores, to_string(metric))
        abs(ensure_float(zscore)) >= @trinity_threshold
      end)

    if all_significant?, do: @trinity_boost, else: 1.0
  end

  def calculate_trinity_boost(_), do: 1.0

  @doc """
  Checks if the Trinity pattern is present in the given z-scores.

  Returns true if all three core signals are significant.
  """
  def trinity_pattern?(zscores) when is_map(zscores) do
    calculate_trinity_boost(zscores) > 1.0
  end

  def trinity_pattern?(_), do: false

  @doc """
  Calculates insider probability from anomaly score, pattern matches, and outcome.

  ## Weights
  - 40% anomaly score
  - 40% pattern match score
  - 20% correct outcome boost

  ## Parameters
  - `anomaly_score` - 0 to 1 anomaly score
  - `pattern_score` - Highest pattern match score (0 to 1)
  - `was_correct` - Whether the trade predicted correctly
  """
  def calculate_insider_probability(anomaly_score, pattern_score, was_correct) do
    anomaly = ensure_float(anomaly_score)
    pattern = ensure_float(pattern_score || 0)
    correct_boost = if was_correct, do: 1.0, else: 0.0

    probability = anomaly * 0.4 + pattern * 0.4 + correct_boost * 0.2

    # Cap at 1.0
    Decimal.from_float(Float.round(min(probability, 1.0), 4))
  end

  @doc """
  Builds a breakdown map of which factors contributed to the anomaly score.
  """
  def build_anomaly_breakdown(zscores_map) do
    zscores_map
    |> Enum.map(fn {metric, zscore} ->
      z = ensure_float(zscore)
      severity = classify_zscore(z)
      {metric, %{zscore: Float.round(z, 3), severity: severity}}
    end)
    |> Map.new()
  end

  defp classify_zscore(z) when abs(z) >= 3.0, do: "extreme"
  defp classify_zscore(z) when abs(z) >= 2.5, do: "very_high"
  defp classify_zscore(z) when abs(z) >= 2.0, do: "high"
  defp classify_zscore(z) when abs(z) >= 1.5, do: "elevated"
  defp classify_zscore(_), do: "normal"

  defp ensure_float(%Decimal{} = d), do: Decimal.to_float(d)
  defp ensure_float(n) when is_float(n), do: n
  defp ensure_float(n) when is_integer(n), do: n * 1.0
  defp ensure_float(nil), do: 0.0
end
