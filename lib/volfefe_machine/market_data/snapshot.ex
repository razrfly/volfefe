defmodule VolfefeMachine.MarketData.Snapshot do
  @moduledoc """
  Market snapshot schema capturing OHLCV data and statistical validation.

  Captures market state at specific points relative to content posting:
  - `before`: Baseline snapshot before message posted
  - `1hr_after`: 1 hour after posting
  - `4hr_after`: 4 hours after posting
  - `24hr_after`: 24 hours after posting

  ## Statistical Validation

  Each snapshot includes:
  - **Z-score**: Statistical significance of price move vs. baseline
  - **Significance level**: "high" (>2σ), "moderate" (>1σ), "noise" (<1σ)
  - **Market state**: Trading hours context
  - **Data validity**: Quality assessment
  - **Isolation score**: Contamination detection (1.0 = isolated, 0.0 = contaminated)

  ## Example

      # Capture snapshot 1 hour after content posted
      %Snapshot{
        content_id: 123,
        asset_id: 1,  # SPY
        window_type: "1hr_after",
        close_price: Decimal.new("450.25"),
        price_change_pct: Decimal.new("0.8"),  # +0.8% move
        z_score: Decimal.new("2.68"),          # 2.68 standard deviations
        significance_level: "high",             # Statistically significant!
        market_state: "regular_hours",
        data_validity: "valid",
        isolation_score: Decimal.new("1.0")    # No nearby messages
      }
  """

  use Ecto.Schema
  import Ecto.Changeset

  schema "market_snapshots" do
    belongs_to :content, VolfefeMachine.Content.Content
    belongs_to :asset, VolfefeMachine.MarketData.Asset

    # Time window
    field :window_type, :string
    field :snapshot_timestamp, :utc_datetime

    # OHLCV data
    field :open_price, :decimal
    field :high_price, :decimal
    field :low_price, :decimal
    field :close_price, :decimal
    field :volume, :integer

    # Calculated metrics
    field :price_change_pct, :decimal
    field :z_score, :decimal
    field :significance_level, :string

    # Volume context
    field :volume_vs_avg, :decimal
    field :volume_z_score, :decimal

    # Market state validation
    field :market_state, :string
    field :data_validity, :string
    field :trading_session_id, :string

    # Contamination detection
    field :isolation_score, :decimal
    field :nearby_content_ids, {:array, :integer}

    timestamps(type: :utc_datetime)
  end

  @valid_window_types ~w(before 1hr_after 4hr_after 24hr_after)
  @valid_market_states ~w(regular_hours extended_hours closed)
  @valid_data_validity ~w(valid stale low_liquidity gap)
  @valid_significance_levels ~w(high moderate noise)

  @doc """
  Creates a changeset for market snapshots.

  ## Required Fields

  - `:content_id` - Reference to content
  - `:asset_id` - Reference to asset
  - `:window_type` - One of: "before", "1hr_after", "4hr_after", "24hr_after"
  - `:snapshot_timestamp` - When snapshot was taken

  ## Validations

  - `window_type` must be one of the valid types
  - Unique constraint on (content_id, asset_id, window_type)
  - `significance_level` must be "high", "moderate", or "noise" if provided
  - `market_state` must be valid if provided
  - `data_validity` must be valid if provided
  - `isolation_score` must be between 0.0 and 1.0 if provided
  """
  def changeset(snapshot, attrs) do
    snapshot
    |> cast(attrs, [
      :content_id, :asset_id,
      :window_type, :snapshot_timestamp,
      :open_price, :high_price, :low_price, :close_price, :volume,
      :price_change_pct, :z_score, :significance_level,
      :volume_vs_avg, :volume_z_score,
      :market_state, :data_validity, :trading_session_id,
      :isolation_score, :nearby_content_ids
    ])
    |> validate_required([:content_id, :asset_id, :window_type, :snapshot_timestamp])
    |> validate_inclusion(:window_type, @valid_window_types)
    |> validate_inclusion(:market_state, @valid_market_states)
    |> validate_inclusion(:data_validity, @valid_data_validity)
    |> validate_inclusion(:significance_level, @valid_significance_levels)
    |> validate_number(:isolation_score, greater_than_or_equal_to: 0.0, less_than_or_equal_to: 1.0)
    |> foreign_key_constraint(:content_id)
    |> foreign_key_constraint(:asset_id)
    |> unique_constraint([:content_id, :asset_id, :window_type], name: :market_snapshots_unique)
  end

  @doc """
  Determines significance level based on z-score.

  ## Significance Levels

  - **high**: |z-score| ≥ 2.0 (95th percentile or higher)
  - **moderate**: 1.0 ≤ |z-score| < 2.0 (68th-95th percentile)
  - **noise**: |z-score| < 1.0 (normal market volatility)

  ## Examples

      iex> Snapshot.calculate_significance_level(2.68)
      "high"

      iex> Snapshot.calculate_significance_level(1.5)
      "moderate"

      iex> Snapshot.calculate_significance_level(0.3)
      "noise"
  """
  def calculate_significance_level(z_score) when is_nil(z_score), do: nil

  def calculate_significance_level(z_score) do
    abs_z = abs(Decimal.to_float(z_score))

    cond do
      abs_z >= 2.0 -> "high"
      abs_z >= 1.0 -> "moderate"
      true -> "noise"
    end
  end

  @doc """
  Calculates z-score for a price change vs. baseline statistics.

  ## Formula

      z_score = (observed_return - mean_return) / std_dev

  ## Parameters

  - `price_change_pct` - Observed price change percentage
  - `baseline` - BaselineStats struct with mean_return and std_dev

  ## Returns

  - Decimal z-score or nil if baseline missing

  ## Example

      baseline = %BaselineStats{mean_return: 0.05, std_dev: 0.28}
      z = Snapshot.calculate_z_score(0.8, baseline)
      # => #Decimal<2.68>  (highly significant!)
  """
  def calculate_z_score(_price_change_pct, baseline) when is_nil(baseline), do: nil

  def calculate_z_score(price_change_pct, baseline) do
    # Check for zero std_dev
    if Decimal.eq?(baseline.std_dev, 0) do
      nil
    else
      calculate_z_score_impl(price_change_pct, baseline)
    end
  end

  defp calculate_z_score_impl(price_change_pct, baseline) do
    observed = Decimal.new(to_string(price_change_pct))
    mean = baseline.mean_return
    std_dev = baseline.std_dev

    Decimal.sub(observed, mean)
    |> Decimal.div(std_dev)
  end

  @doc """
  Determines market state based on timestamp.

  ## Market States

  - **regular_hours**: NYSE 9:30 AM - 4:00 PM ET
  - **extended_hours**: Pre-market (4:00-9:30 AM) or after-hours (4:00-8:00 PM) ET
  - **closed**: Weekends or outside trading hours

  ## Parameters

  - `timestamp` - DateTime in UTC

  ## Returns

  - String: "regular_hours", "extended_hours", or "closed"
  """
  def determine_market_state(timestamp) do
    # Convert UTC to Eastern Time (simplified - doesn't handle DST)
    # For production, use a proper timezone library like tzdata
    et_hour = rem(timestamp.hour - 5, 24)  # Rough UTC to ET conversion
    weekday = Date.day_of_week(timestamp)

    cond do
      # Weekend
      weekday in [6, 7] -> "closed"

      # Regular hours: 9:30 AM - 4:00 PM ET
      et_hour >= 9 and (et_hour < 16 or (et_hour == 9 and timestamp.minute >= 30)) -> "regular_hours"

      # Extended hours: 4:00 AM - 9:30 AM or 4:00 PM - 8:00 PM ET
      (et_hour >= 4 and et_hour < 9) or (et_hour >= 16 and et_hour < 20) -> "extended_hours"

      # Closed
      true -> "closed"
    end
  end

  @doc """
  Determines data validity based on market state and age.

  ## Validity States

  - **valid**: Recent data during regular hours
  - **stale**: Data more than 15 minutes old
  - **low_liquidity**: Extended hours or low volume
  - **gap**: Data from when market was closed

  ## Parameters

  - `snapshot_timestamp` - When snapshot was captured
  - `market_state` - Result from determine_market_state/1
  - `volume` - Trading volume (optional)
  - `avg_volume` - Average historical volume (optional)

  ## Returns

  - String: validity state
  """
  def determine_data_validity(snapshot_timestamp, market_state, volume \\ nil, avg_volume \\ nil) do
    now = DateTime.utc_now()
    age_minutes = DateTime.diff(now, snapshot_timestamp, :minute)

    cond do
      # Market closed - data is a gap
      market_state == "closed" -> "gap"

      # Data more than 15 minutes old
      age_minutes > 15 -> "stale"

      # Extended hours with low volume
      market_state == "extended_hours" and is_low_volume?(volume, avg_volume) -> "low_liquidity"

      # Extended hours with decent volume
      market_state == "extended_hours" -> "valid"

      # Regular hours - generally valid
      true -> "valid"
    end
  end

  defp is_low_volume?(nil, _avg_volume), do: true
  defp is_low_volume?(_volume, nil), do: false
  defp is_low_volume?(_volume, avg_volume) when avg_volume == 0, do: true
  defp is_low_volume?(volume, avg_volume) do
    volume / avg_volume < 0.3  # Less than 30% of average volume
  end
end
