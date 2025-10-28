defmodule VolfefeMachine.Repo.Migrations.CreateMarketSnapshots do
  use Ecto.Migration

  def change do
    create table(:market_snapshots) do
      add :content_id, references(:contents, on_delete: :delete_all), null: false
      add :asset_id, references(:assets, on_delete: :delete_all), null: false

      # Time window
      add :window_type, :string, null: false
      add :snapshot_timestamp, :utc_datetime, null: false

      # OHLCV data
      add :open_price, :decimal, precision: 20, scale: 8
      add :high_price, :decimal, precision: 20, scale: 8
      add :low_price, :decimal, precision: 20, scale: 8
      add :close_price, :decimal, precision: 20, scale: 8
      add :volume, :bigint

      # Calculated metrics
      add :price_change_pct, :decimal, precision: 10, scale: 4
      add :z_score, :decimal, precision: 8, scale: 4
      add :significance_level, :string

      # Volume context
      add :volume_vs_avg, :decimal, precision: 8, scale: 4
      add :volume_z_score, :decimal, precision: 8, scale: 4

      # Market state validation
      add :market_state, :string
      add :data_validity, :string
      add :trading_session_id, :string

      # Contamination detection
      add :isolation_score, :decimal, precision: 4, scale: 2
      add :nearby_content_ids, {:array, :bigint}

      timestamps(type: :utc_datetime)
    end

    # Indexes
    create index(:market_snapshots, [:content_id])
    create index(:market_snapshots, [:asset_id])
    create index(:market_snapshots, [:window_type])
    create index(:market_snapshots, [:significance_level])
    create index(:market_snapshots, [:z_score], where: "z_score > 1.5")

    # Unique constraint: one snapshot per content + asset + window combination
    create unique_index(:market_snapshots, [:content_id, :asset_id, :window_type],
                        name: :market_snapshots_unique)

    # Check constraint for window_type
    create constraint(:market_snapshots, :valid_window_type,
                      check: "window_type IN ('before', '1hr_after', '4hr_after', '24hr_after')")
  end
end
