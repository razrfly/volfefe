defmodule VolfefeMachine.Repo.Migrations.CreatePolymarketTables do
  use Ecto.Migration

  def change do
    # Create market category enum
    execute(
      "CREATE TYPE polymarket_category AS ENUM ('politics', 'corporate', 'legal', 'crypto', 'sports', 'entertainment', 'science', 'other')",
      "DROP TYPE polymarket_category"
    )

    # ============================================
    # Table 1: Markets (Cache)
    # ============================================
    create table(:polymarket_markets) do
      # API reference
      add :condition_id, :string, null: false

      # Market details
      add :question, :text, null: false
      add :description, :text
      add :slug, :string
      add :outcomes, :map, default: %{"options" => ["Yes", "No"]}
      add :outcome_prices, :map

      # Timing
      add :end_date, :utc_datetime
      add :resolution_date, :utc_datetime
      add :resolved_outcome, :string

      # Volume & liquidity
      add :volume, :decimal, precision: 20, scale: 2
      add :volume_24hr, :decimal, precision: 20, scale: 2
      add :liquidity, :decimal, precision: 20, scale: 2

      # Classification
      add :category, :polymarket_category, default: "other"
      add :is_event_based, :boolean, default: true
      add :is_active, :boolean, default: true

      # Raw API response
      add :meta, :map

      # Cache metadata
      add :last_synced_at, :utc_datetime

      timestamps(type: :utc_datetime)
    end

    create unique_index(:polymarket_markets, [:condition_id])
    create index(:polymarket_markets, [:category])
    create index(:polymarket_markets, [:is_event_based])
    create index(:polymarket_markets, [:is_active])
    create index(:polymarket_markets, [:resolution_date])
    create index(:polymarket_markets, [:end_date])

    # ============================================
    # Table 2: Wallets (Cache + Aggregates)
    # ============================================
    create table(:polymarket_wallets) do
      # API reference
      add :address, :string, null: false
      add :pseudonym, :string
      add :display_name, :string

      # Aggregates (computed from trades)
      add :total_trades, :integer, default: 0
      add :total_volume, :decimal, precision: 20, scale: 2, default: 0
      add :unique_markets, :integer, default: 0

      # Win/Loss tracking
      add :resolved_positions, :integer, default: 0
      add :wins, :integer, default: 0
      add :losses, :integer, default: 0
      add :win_rate, :decimal, precision: 5, scale: 4

      # Activity timeline
      add :first_seen_at, :utc_datetime
      add :last_seen_at, :utc_datetime

      # Cache metadata
      add :last_aggregated_at, :utc_datetime

      timestamps(type: :utc_datetime)
    end

    create unique_index(:polymarket_wallets, [:address])
    create index(:polymarket_wallets, [:win_rate])
    create index(:polymarket_wallets, [:total_trades])

    # ============================================
    # Table 3: Trades (Cache)
    # ============================================
    create table(:polymarket_trades) do
      # API reference
      add :transaction_hash, :string, null: false

      # Foreign keys
      add :market_id, references(:polymarket_markets, on_delete: :delete_all)
      add :wallet_id, references(:polymarket_wallets, on_delete: :nilify_all)

      # Denormalized for fast queries
      add :wallet_address, :string, null: false
      add :condition_id, :string, null: false

      # Trade details
      add :side, :string, null: false  # BUY, SELL
      add :outcome, :string, null: false  # Yes, No
      add :outcome_index, :integer
      add :size, :decimal, precision: 20, scale: 6, null: false
      add :price, :decimal, precision: 10, scale: 8, null: false
      add :usdc_size, :decimal, precision: 20, scale: 6
      add :trade_timestamp, :utc_datetime, null: false

      # Calculated metrics (computed on ingest or later)
      add :size_percentile, :decimal, precision: 5, scale: 4
      add :hours_before_resolution, :decimal, precision: 10, scale: 2
      add :wallet_age_days, :integer
      add :wallet_trade_count, :integer
      add :price_extremity, :decimal, precision: 5, scale: 4

      # Outcome tracking (updated after market resolution)
      add :was_correct, :boolean
      add :profit_loss, :decimal, precision: 20, scale: 2

      # Raw API response
      add :meta, :map

      timestamps(type: :utc_datetime)
    end

    create unique_index(:polymarket_trades, [:transaction_hash])
    create index(:polymarket_trades, [:market_id])
    create index(:polymarket_trades, [:wallet_id])
    create index(:polymarket_trades, [:wallet_address])
    create index(:polymarket_trades, [:condition_id])
    create index(:polymarket_trades, [:trade_timestamp])
    create index(:polymarket_trades, [:was_correct])

    # Composite index for common query patterns
    create index(:polymarket_trades, [:market_id, :trade_timestamp])
    create index(:polymarket_trades, [:wallet_address, :trade_timestamp])
  end
end
