defmodule VolfefeMachine.Repo.Migrations.CreatePolymarketAlerts do
  use Ecto.Migration

  def change do
    create table(:polymarket_alerts) do
      add :trade_id, references(:polymarket_trades, on_delete: :nothing)
      add :trade_score_id, references(:polymarket_trade_scores, on_delete: :nothing)
      add :market_id, references(:polymarket_markets, on_delete: :nothing)

      # Alert identification
      add :alert_id, :string, null: false
      add :alert_type, :string, null: false  # pattern_match, anomaly_threshold, whale_trade, etc.

      # Trade context
      add :transaction_hash, :string
      add :wallet_address, :string, null: false
      add :condition_id, :string

      # Alert details
      add :severity, :string, default: "medium"  # low, medium, high, critical
      add :anomaly_score, :decimal, precision: 5, scale: 4
      add :insider_probability, :decimal, precision: 5, scale: 4

      # Context (denormalized for quick display)
      add :market_question, :text
      add :trade_size, :decimal, precision: 20, scale: 6
      add :trade_outcome, :string
      add :trade_price, :decimal, precision: 10, scale: 4

      # Pattern matching
      add :matched_patterns, :map
      add :highest_pattern_score, :decimal, precision: 5, scale: 4

      # Alert lifecycle
      add :status, :string, default: "new"  # new, acknowledged, investigating, resolved, dismissed
      add :acknowledged_at, :utc_datetime
      add :acknowledged_by, :string
      add :resolution, :string
      add :resolution_notes, :text

      # Notification tracking
      add :notifications_sent, :map, default: %{}

      # Timestamps
      add :triggered_at, :utc_datetime, null: false
      add :trade_timestamp, :utc_datetime

      timestamps(type: :utc_datetime)
    end

    create unique_index(:polymarket_alerts, [:alert_id])
    create index(:polymarket_alerts, [:status])
    create index(:polymarket_alerts, [:severity])
    create index(:polymarket_alerts, [:wallet_address])
    create index(:polymarket_alerts, [:triggered_at])
    create index(:polymarket_alerts, [:trade_id])
  end
end
