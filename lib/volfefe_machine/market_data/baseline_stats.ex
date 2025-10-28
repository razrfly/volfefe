defmodule VolfefeMachine.MarketData.BaselineStats do
  @moduledoc """
  Schema for baseline statistical measures of asset returns.

  Stores historical statistical norms (mean, std dev, percentiles) for different
  time windows (1hr, 4hr, 24hr) to enable significance testing of price moves.

  ## Purpose

  When a message is posted and the market moves, we need to know if that move is
  statistically significant or just normal market volatility. This table provides
  the baseline statistics to calculate z-scores:

      z_score = (observed_return - mean_return) / std_dev

  ## Fields

  * `:asset_id` - Reference to the asset
  * `:window_minutes` - Time window (60, 240, 1440)
  * `:mean_return` - Average return for this window (percentage)
  * `:std_dev` - Standard deviation of returns (percentage)
  * `:percentile_50` - Median return (50th percentile)
  * `:percentile_95` - 95th percentile threshold
  * `:percentile_99` - 99th percentile threshold
  * `:mean_volume` - Average volume for this window
  * `:volume_std_dev` - Standard deviation of volume
  * `:sample_size` - Number of observations used
  * `:sample_period_start` - Start of historical sample period
  * `:sample_period_end` - End of historical sample period

  ## Example

      # Get baseline stats for SPY 1-hour window
      baseline = Repo.get_by(BaselineStats, asset_id: spy.id, window_minutes: 60)

      # SPY typically moves +0.05% per hour with 0.28% std dev
      baseline.mean_return    # => 0.05
      baseline.std_dev        # => 0.28

      # Calculate if observed move is significant
      observed_return = 0.8  # SPY moved +0.8%
      z_score = (observed_return - baseline.mean_return) / baseline.std_dev
      # => (0.8 - 0.05) / 0.28 = 2.68 (highly significant!)
  """

  use Ecto.Schema
  import Ecto.Changeset

  schema "asset_baseline_stats" do
    belongs_to :asset, VolfefeMachine.MarketData.Asset

    field :window_minutes, :integer

    # Return statistics (percentage)
    field :mean_return, :decimal
    field :std_dev, :decimal
    field :percentile_50, :decimal
    field :percentile_95, :decimal
    field :percentile_99, :decimal

    # Volume statistics
    field :mean_volume, :integer
    field :volume_std_dev, :integer

    # Sample metadata
    field :sample_size, :integer
    field :sample_period_start, :utc_datetime
    field :sample_period_end, :utc_datetime

    timestamps(type: :utc_datetime)
  end

  @valid_windows [60, 240, 1440]

  @doc """
  Creates a changeset for baseline statistics.

  ## Validations

  * Required: asset_id, window_minutes, mean_return, std_dev
  * window_minutes must be one of: 60, 240, 1440
  * Unique constraint on (asset_id, window_minutes)
  """
  def changeset(baseline_stats, attrs) do
    baseline_stats
    |> cast(attrs, [
      :asset_id, :window_minutes,
      :mean_return, :std_dev,
      :percentile_50, :percentile_95, :percentile_99,
      :mean_volume, :volume_std_dev,
      :sample_size, :sample_period_start, :sample_period_end
    ])
    |> validate_required([:asset_id, :window_minutes, :mean_return, :std_dev])
    |> validate_inclusion(:window_minutes, @valid_windows)
    |> foreign_key_constraint(:asset_id)
    |> unique_constraint([:asset_id, :window_minutes], name: :asset_baseline_stats_unique)
  end
end
