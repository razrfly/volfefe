defmodule VolfefeMachine.Repo.Migrations.CreatePolymarketDiscoveryTables do
  use Ecto.Migration

  def change do
    # Discovery Batches - Track analysis runs
    create table(:polymarket_discovery_batches) do
      add :batch_id, :string, null: false
      add :markets_analyzed, :integer
      add :trades_scored, :integer
      add :candidates_generated, :integer

      add :anomaly_threshold, :decimal, precision: 5, scale: 4
      add :probability_threshold, :decimal, precision: 5, scale: 4
      add :filters, :map

      add :patterns_version, :string
      add :baselines_version, :string

      add :top_candidate_score, :decimal, precision: 5, scale: 4
      add :median_candidate_score, :decimal, precision: 5, scale: 4

      add :started_at, :utc_datetime
      add :completed_at, :utc_datetime
      add :notes, :text

      timestamps(type: :utc_datetime)
    end

    create unique_index(:polymarket_discovery_batches, [:batch_id])

    # Investigation Candidates - Top suspicious trades for review
    create table(:polymarket_investigation_candidates) do
      add :trade_id, references(:polymarket_trades, on_delete: :nothing)
      add :trade_score_id, references(:polymarket_trade_scores, on_delete: :nothing)
      add :market_id, references(:polymarket_markets, on_delete: :nothing)

      # API references for re-fetching
      add :transaction_hash, :string
      add :wallet_address, :string, null: false
      add :condition_id, :string

      # Ranking
      add :discovery_rank, :integer, null: false
      add :anomaly_score, :decimal, precision: 5, scale: 4, null: false
      add :insider_probability, :decimal, precision: 5, scale: 4, null: false

      # Context (denormalized for display)
      add :market_question, :text
      add :trade_size, :decimal, precision: 20, scale: 6
      add :trade_outcome, :string
      add :was_correct, :boolean
      add :estimated_profit, :decimal, precision: 20, scale: 2
      add :hours_before_resolution, :decimal, precision: 10, scale: 2

      # Anomaly details
      add :anomaly_breakdown, :map
      add :matched_patterns, :map

      # Investigation workflow
      add :status, :string, default: "undiscovered"
      add :priority, :string, default: "medium"
      add :assigned_to, :string
      add :investigation_started_at, :utc_datetime
      add :investigation_notes, :text
      add :resolved_at, :utc_datetime
      add :resolved_by, :string
      add :resolution_evidence, :map

      # Batch tracking
      add :batch_id, :string
      add :discovered_at, :utc_datetime, default: fragment("NOW()")

      timestamps(type: :utc_datetime)
    end

    create unique_index(:polymarket_investigation_candidates, [:trade_id])
    create index(:polymarket_investigation_candidates, [:status])
    create index(:polymarket_investigation_candidates, [:discovery_rank])
    create index(:polymarket_investigation_candidates, [:batch_id])
    create index(:polymarket_investigation_candidates, [:wallet_address])
    create index(:polymarket_investigation_candidates, [:insider_probability])
  end
end
