defmodule VolfefeMachine.Repo.Migrations.CreateAssetBaselineStats do
  use Ecto.Migration

  def change do
    create table(:asset_baseline_stats) do
      add :asset_id, references(:assets, on_delete: :delete_all), null: false

      # Time window in minutes (60 = 1hr, 240 = 4hr, 1440 = 24hr)
      add :window_minutes, :integer, null: false

      # Statistical measures for returns (percentage)
      add :mean_return, :decimal, precision: 10, scale: 6
      add :std_dev, :decimal, precision: 10, scale: 6
      add :percentile_50, :decimal, precision: 10, scale: 6
      add :percentile_95, :decimal, precision: 10, scale: 6
      add :percentile_99, :decimal, precision: 10, scale: 6

      # Volume statistics
      add :mean_volume, :bigint
      add :volume_std_dev, :bigint

      # Sample metadata
      add :sample_size, :integer
      add :sample_period_start, :utc_datetime
      add :sample_period_end, :utc_datetime

      timestamps(type: :utc_datetime)
    end

    # Indexes
    create index(:asset_baseline_stats, [:asset_id])
    create index(:asset_baseline_stats, [:window_minutes])

    # Unique constraint: one baseline per asset + window combination
    create unique_index(:asset_baseline_stats, [:asset_id, :window_minutes],
                        name: :asset_baseline_stats_unique)
  end
end
