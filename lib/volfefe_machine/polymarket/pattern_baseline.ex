defmodule VolfefeMachine.Polymarket.PatternBaseline do
  @moduledoc """
  Ecto schema for pattern baselines.

  Stores statistical distributions (mean, stddev, percentiles) for each metric
  segmented by market category. Used for z-score anomaly detection.

  ## Metrics Tracked

  - `size` - Trade size in outcome tokens
  - `usdc_size` - Trade size in USDC
  - `timing` - Hours before market resolution
  - `wallet_age` - Wallet age in days at time of trade
  - `wallet_activity` - Wallet's total trade count at time of trade
  - `price_extremity` - Distance from 0.5 (even odds)

  ## Usage

      # Get baseline for a specific metric/category
      baseline = Repo.get_by(PatternBaseline, market_category: "politics", metric_name: "size")

      # Calculate z-score
      z = (trade_size - baseline.normal_mean) / baseline.normal_stddev
  """

  use Ecto.Schema
  import Ecto.Changeset

  @metric_names ~w(size usdc_size timing wallet_age wallet_activity price_extremity)
  @market_categories ~w(politics corporate legal crypto sports entertainment science other all)

  schema "polymarket_pattern_baselines" do
    field :market_category, :string
    field :metric_name, :string

    # Normal distribution (from all trades)
    field :normal_mean, :decimal
    field :normal_stddev, :decimal
    field :normal_median, :decimal
    field :normal_p75, :decimal
    field :normal_p90, :decimal
    field :normal_p95, :decimal
    field :normal_p99, :decimal
    field :normal_sample_count, :integer

    # For Welford's online algorithm (incremental updates)
    field :normal_m2, :decimal  # Sum of squared differences from mean
    field :last_trade_timestamp, :utc_datetime  # Track last processed trade

    # Insider distribution (from confirmed insiders)
    field :insider_mean, :decimal
    field :insider_stddev, :decimal
    field :insider_sample_count, :integer, default: 0

    # Statistical separation score between normal and insider
    field :separation_score, :decimal

    field :calculated_at, :utc_datetime

    timestamps(type: :utc_datetime)
  end

  @required_fields ~w(market_category metric_name)a
  @optional_fields ~w(
    normal_mean normal_stddev normal_median
    normal_p75 normal_p90 normal_p95 normal_p99 normal_sample_count
    normal_m2 last_trade_timestamp
    insider_mean insider_stddev insider_sample_count
    separation_score calculated_at
  )a

  def changeset(baseline, attrs) do
    baseline
    |> cast(attrs, @required_fields ++ @optional_fields)
    |> validate_required(@required_fields)
    |> validate_inclusion(:metric_name, @metric_names)
    |> validate_inclusion(:market_category, @market_categories)
    |> unique_constraint([:market_category, :metric_name])
  end

  @doc """
  Returns the list of valid metric names.
  """
  def metric_names, do: @metric_names

  @doc """
  Returns the list of valid market categories.
  """
  def market_categories, do: @market_categories

  @doc """
  Calculates z-score for a value given this baseline.
  Returns nil if stddev is 0 or nil.
  """
  def calculate_zscore(%__MODULE__{normal_mean: mean, normal_stddev: stddev}, value)
      when not is_nil(mean) and not is_nil(stddev) and not is_nil(value) do
    stddev_float = Decimal.to_float(stddev)

    if stddev_float > 0 do
      mean_float = Decimal.to_float(mean)
      value_float = ensure_float(value)
      (value_float - mean_float) / stddev_float
    else
      nil
    end
  end

  # Return nil for nil values - don't convert to 0!
  def calculate_zscore(_, nil), do: nil
  def calculate_zscore(_, _), do: nil

  @doc """
  Calculates the separation score between normal and insider distributions.
  Uses Cohen's d: (insider_mean - normal_mean) / pooled_stddev
  Higher values indicate better separation (easier to detect insiders).
  """
  def calculate_separation(%__MODULE__{} = baseline) do
    with %{normal_mean: nm, normal_stddev: ns, insider_mean: im, insider_stddev: is}
         when not is_nil(nm) and not is_nil(ns) and not is_nil(im) and not is_nil(is) <- baseline do
      nm_f = Decimal.to_float(nm)
      ns_f = Decimal.to_float(ns)
      im_f = Decimal.to_float(im)
      is_f = Decimal.to_float(is)

      # Pooled standard deviation
      pooled_stddev = :math.sqrt((ns_f * ns_f + is_f * is_f) / 2)

      if pooled_stddev > 0 do
        abs(im_f - nm_f) / pooled_stddev
      else
        nil
      end
    else
      _ -> nil
    end
  end

  defp ensure_float(%Decimal{} = d), do: Decimal.to_float(d)
  defp ensure_float(n) when is_float(n), do: n
  defp ensure_float(n) when is_integer(n), do: n * 1.0
  # Don't convert nil to 0 - this was causing all nil values to get fake z-scores!
  defp ensure_float(nil), do: nil
end
