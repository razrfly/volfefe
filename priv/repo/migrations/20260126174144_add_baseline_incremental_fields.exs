defmodule VolfefeMachine.Repo.Migrations.AddBaselineIncrementalFields do
  use Ecto.Migration

  def change do
    alter table(:polymarket_pattern_baselines) do
      # For Welford's online algorithm: M2 = sum of squared differences from mean
      # variance = M2 / (n - 1), stddev = sqrt(variance)
      add :normal_m2, :decimal, precision: 30, scale: 10

      # Track last processed trade timestamp for incremental updates
      add :last_trade_timestamp, :utc_datetime
    end

    # Index for efficient incremental queries (if_not_exists for idempotency)
    create_if_not_exists index(:polymarket_trades, [:trade_timestamp], where: "trade_timestamp IS NOT NULL")
  end
end
