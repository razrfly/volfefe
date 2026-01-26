defmodule VolfefeMachine.Repo.Migrations.AddMlFeatureFields do
  use Ecto.Migration

  @moduledoc """
  Add ML feature fields for expanded 22-feature anomaly detection.

  Expands from 7 z-score features to 22 total features including:
  - Raw normalized values
  - Wallet-level statistics
  - Contextual time features
  - ML model outputs
  """

  def change do
    alter table(:polymarket_trade_scores) do
      # === Extended Features (8-15) ===
      # Raw normalized values (not z-scores)
      add :raw_size_normalized, :decimal, precision: 15, scale: 6
      add :raw_price, :decimal, precision: 10, scale: 6
      add :raw_hours_before_resolution, :decimal, precision: 15, scale: 2
      add :raw_wallet_age_days, :integer
      add :raw_wallet_trade_count, :integer

      # Binary/categorical features
      add :is_buy, :boolean
      add :outcome_index, :integer

      # Derived confidence measure
      add :price_confidence, :decimal, precision: 10, scale: 6

      # === Wallet-Level Features (16-19) ===
      add :wallet_win_rate, :decimal, precision: 10, scale: 6
      add :wallet_volume_zscore, :decimal, precision: 15, scale: 6
      add :wallet_unique_markets_normalized, :decimal, precision: 10, scale: 6
      add :funding_amount_normalized, :decimal, precision: 15, scale: 6

      # === Contextual Features (20-22) ===
      add :trade_hour_sin, :decimal, precision: 10, scale: 6  # sin(2π * hour/24)
      add :trade_hour_cos, :decimal, precision: 10, scale: 6  # cos(2π * hour/24)
      add :trade_day_sin, :decimal, precision: 10, scale: 6   # sin(2π * day/7)
      add :trade_day_cos, :decimal, precision: 10, scale: 6   # cos(2π * day/7)

      # === ML Model Outputs ===
      add :ml_anomaly_score, :decimal, precision: 10, scale: 6
      add :ml_confidence, :decimal, precision: 10, scale: 6

      # Ensemble score combining rules + ML
      add :ensemble_score, :decimal, precision: 10, scale: 6

      # Trinity pattern flag
      add :trinity_pattern, :boolean, default: false
    end

    # Index for ML queries
    create_if_not_exists index(:polymarket_trade_scores, [:ml_anomaly_score],
      where: "ml_anomaly_score IS NOT NULL"
    )

    create_if_not_exists index(:polymarket_trade_scores, [:ensemble_score],
      where: "ensemble_score IS NOT NULL"
    )
  end
end
