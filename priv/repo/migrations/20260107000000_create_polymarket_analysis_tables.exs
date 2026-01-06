defmodule VolfefeMachine.Repo.Migrations.CreatePolymarketAnalysisTables do
  use Ecto.Migration

  def change do
    # Phase 3: Pattern Baselines - statistical distributions for anomaly detection
    create table(:polymarket_pattern_baselines) do
      add :market_category, :string, null: false
      add :metric_name, :string, null: false

      # Normal distribution (calculated from all trades)
      add :normal_mean, :decimal, precision: 20, scale: 6
      add :normal_stddev, :decimal, precision: 20, scale: 6
      add :normal_median, :decimal, precision: 20, scale: 6
      add :normal_p75, :decimal, precision: 20, scale: 6
      add :normal_p90, :decimal, precision: 20, scale: 6
      add :normal_p95, :decimal, precision: 20, scale: 6
      add :normal_p99, :decimal, precision: 20, scale: 6
      add :normal_sample_count, :integer

      # Insider distribution (from confirmed insiders - Phase 4+)
      add :insider_mean, :decimal, precision: 20, scale: 6
      add :insider_stddev, :decimal, precision: 20, scale: 6
      add :insider_sample_count, :integer, default: 0

      # Statistical separation
      add :separation_score, :decimal, precision: 5, scale: 4

      add :calculated_at, :utc_datetime

      timestamps(type: :utc_datetime)
    end

    create unique_index(:polymarket_pattern_baselines, [:market_category, :metric_name])

    # Phase 5: Insider Patterns - detection rule definitions
    create table(:polymarket_insider_patterns) do
      add :pattern_name, :string, null: false
      add :description, :text

      # Pattern conditions as JSON (flexible rule system)
      add :conditions, :map, null: false

      # Performance metrics
      add :true_positives, :integer, default: 0
      add :false_positives, :integer, default: 0
      add :precision, :decimal, precision: 5, scale: 4
      add :recall, :decimal, precision: 5, scale: 4
      add :f1_score, :decimal, precision: 5, scale: 4

      # Thresholds
      add :alert_threshold, :decimal, precision: 5, scale: 4
      add :lift, :decimal, precision: 10, scale: 4

      add :is_active, :boolean, default: true
      add :validated_at, :utc_datetime

      timestamps(type: :utc_datetime)
    end

    create unique_index(:polymarket_insider_patterns, [:pattern_name])

    # Phase 6: Trade Scores - computed anomaly scores per trade
    create table(:polymarket_trade_scores) do
      add :trade_id, references(:polymarket_trades, on_delete: :delete_all)
      add :transaction_hash, :string

      # Z-Scores (how many stddevs from mean)
      add :size_zscore, :decimal, precision: 6, scale: 3
      add :timing_zscore, :decimal, precision: 6, scale: 3
      add :wallet_age_zscore, :decimal, precision: 6, scale: 3
      add :wallet_activity_zscore, :decimal, precision: 6, scale: 3
      add :price_extremity_zscore, :decimal, precision: 6, scale: 3

      # Combined scores
      add :anomaly_score, :decimal, precision: 5, scale: 4
      add :insider_probability, :decimal, precision: 5, scale: 4

      # Pattern matches
      add :matched_patterns, :map
      add :highest_pattern_score, :decimal, precision: 5, scale: 4

      # Discovery ranking
      add :discovery_rank, :integer

      add :scored_at, :utc_datetime

      timestamps(type: :utc_datetime)
    end

    create unique_index(:polymarket_trade_scores, [:trade_id])
    create index(:polymarket_trade_scores, [:anomaly_score])
    create index(:polymarket_trade_scores, [:insider_probability])
    create index(:polymarket_trade_scores, [:discovery_rank])

    # Phase 7: Investigation Candidates - top suspicious trades for review
    create table(:polymarket_investigation_candidates) do
      add :trade_id, references(:polymarket_trades, on_delete: :delete_all)
      add :trade_score_id, references(:polymarket_trade_scores, on_delete: :delete_all)
      add :market_id, references(:polymarket_markets, on_delete: :delete_all)

      # API references
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
      add :discovered_at, :utc_datetime

      timestamps(type: :utc_datetime)
    end

    create unique_index(:polymarket_investigation_candidates, [:trade_id])
    create index(:polymarket_investigation_candidates, [:status])
    create index(:polymarket_investigation_candidates, [:discovery_rank])
    create index(:polymarket_investigation_candidates, [:batch_id])

    # Phase 4 & 8: Confirmed Insiders - labeled training data
    create table(:polymarket_confirmed_insiders) do
      add :trade_id, references(:polymarket_trades, on_delete: :delete_all)
      add :candidate_id, references(:polymarket_investigation_candidates, on_delete: :nilify_all)

      # API references
      add :transaction_hash, :string
      add :wallet_address, :string, null: false
      add :condition_id, :string

      # Confirmation
      add :confidence_level, :string, null: false  # suspected, likely, confirmed
      add :confirmation_source, :string, null: false

      # Evidence
      add :evidence_summary, :text
      add :evidence_links, :map

      # Financial
      add :trade_size, :decimal, precision: 20, scale: 6
      add :estimated_profit, :decimal, precision: 20, scale: 2

      # Training
      add :used_for_training, :boolean, default: false
      add :training_weight, :decimal, precision: 3, scale: 2, default: 1.0

      add :confirmed_at, :utc_datetime
      add :confirmed_by, :string

      timestamps(type: :utc_datetime)
    end

    create unique_index(:polymarket_confirmed_insiders, [:trade_id])
    create index(:polymarket_confirmed_insiders, [:confidence_level])

    # Phase 10: Alerts - real-time monitoring alerts
    create table(:polymarket_alerts) do
      add :trade_id, references(:polymarket_trades, on_delete: :delete_all)
      add :trade_score_id, references(:polymarket_trade_scores, on_delete: :delete_all)

      # API references
      add :transaction_hash, :string
      add :wallet_address, :string
      add :condition_id, :string

      # Alert details
      add :severity, :string, null: false  # low, medium, high, critical
      add :insider_probability, :decimal, precision: 5, scale: 4
      add :anomaly_score, :decimal, precision: 5, scale: 4

      add :matched_patterns, :map
      add :anomaly_breakdown, :map

      # Context
      add :trade_size, :decimal, precision: 20, scale: 6
      add :trade_outcome, :string
      add :hours_before_resolution, :decimal, precision: 10, scale: 2

      # Review workflow
      add :status, :string, default: "pending"
      add :reviewed_by, :string
      add :reviewed_at, :utc_datetime
      add :review_notes, :text

      # Outcome tracking
      add :trade_was_correct, :boolean
      add :actual_profit, :decimal, precision: 20, scale: 2

      timestamps(type: :utc_datetime)
    end

    create index(:polymarket_alerts, [:status])
    create index(:polymarket_alerts, [:severity])

    # Discovery Batches - analysis run tracking
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
  end
end
