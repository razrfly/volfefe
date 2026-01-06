defmodule VolfefeMachine.Polymarket.TradeScore do
  @moduledoc """
  Ecto schema for trade scores.

  Stores computed anomaly metrics for each trade:
  - Z-scores for each metric (how many stddevs from normal)
  - Composite anomaly score
  - Insider probability estimate
  - Pattern matches

  ## Scoring Formula

  **Z-Score**: `(value - mean) / stddev`
  - |z| > 2.0 → Unusual (top 2.5%)
  - |z| > 2.5 → Very unusual (top 0.6%)
  - |z| > 3.0 → Extreme (top 0.1%)

  **Anomaly Score**: Normalized RMS of z-scores
  ```
  anomaly_score = sqrt(sum(z²)) / sqrt(n) / 3.0
  ```
  Capped at 1.0, where 1.0 = extreme outlier on all dimensions.

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

    # Z-Scores (standard deviations from mean)
    field :size_zscore, :decimal
    field :timing_zscore, :decimal
    field :wallet_age_zscore, :decimal
    field :wallet_activity_zscore, :decimal
    field :price_extremity_zscore, :decimal

    # Combined scores
    field :anomaly_score, :decimal
    field :insider_probability, :decimal

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
    anomaly_score insider_probability
    matched_patterns highest_pattern_score
    discovery_rank scored_at
  )a

  def changeset(score, attrs) do
    score
    |> cast(attrs, @optional_fields)
    |> unique_constraint(:trade_id)
  end

  @doc """
  Calculates composite anomaly score from z-scores.

  Uses root mean square normalized by max expected z-score (3.0).
  Result is capped between 0 and 1.
  """
  def calculate_anomaly_score(zscores) when is_list(zscores) do
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
