defmodule VolfefeMachine.Repo.Migrations.CreatePolymarketPredictions do
  use Ecto.Migration

  def change do
    create table(:polymarket_predictions) do
      # Identifiers
      add :prediction_id, :string, null: false
      add :market_id, references(:polymarket_markets, on_delete: :nothing)
      add :condition_id, :string
      add :market_question, :text
      add :market_category, :string

      # Timing
      add :predicted_at, :utc_datetime, null: false
      add :market_end_date, :utc_datetime

      # Prediction data (snapshot at prediction time)
      add :watchability_score, :decimal, precision: 10, scale: 6
      add :max_ensemble_score, :decimal, precision: 10, scale: 6
      add :avg_ensemble_score, :decimal, precision: 10, scale: 6
      add :suspicious_trade_count, :integer, default: 0
      add :suspicious_volume, :decimal, precision: 20, scale: 2
      add :unique_suspicious_wallets, :integer, default: 0

      # Top wallet info
      add :top_wallet_address, :string
      add :top_wallet_score, :decimal, precision: 10, scale: 6
      add :top_wallet_trade_count, :integer

      # Prediction outcome
      add :predicted_outcome, :string
      add :prediction_confidence, :decimal, precision: 5, scale: 4
      add :prediction_tier, :string  # critical, high, medium, low

      # Consensus data (what suspicious traders are betting on)
      add :suspicious_yes_volume, :decimal, precision: 20, scale: 2
      add :suspicious_no_volume, :decimal, precision: 20, scale: 2

      # Resolution tracking (filled when market resolves)
      add :actual_outcome, :string
      add :validated_at, :utc_datetime
      add :prediction_correct, :boolean
      add :days_before_resolution, :decimal, precision: 10, scale: 2
      add :validation_notes, :text

      timestamps()
    end

    # Indexes
    create unique_index(:polymarket_predictions, [:prediction_id])
    create index(:polymarket_predictions, [:market_id])
    create index(:polymarket_predictions, [:condition_id])
    create index(:polymarket_predictions, [:predicted_at])
    create index(:polymarket_predictions, [:validated_at])
    create index(:polymarket_predictions, [:prediction_tier])
    create index(:polymarket_predictions, [:prediction_correct])

    # Composite index for finding unvalidated predictions
    create index(:polymarket_predictions, [:validated_at, :market_id],
      where: "validated_at IS NULL",
      name: :polymarket_predictions_pending_validation_idx
    )
  end
end
