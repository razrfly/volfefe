defmodule VolfefeMachine.Repo.Migrations.CreateAssets do
  use Ecto.Migration

  def change do
    # Create enum types for asset classification
    execute(
      """
      CREATE TYPE asset_class AS ENUM (
        'us_equity',
        'crypto',
        'us_option',
        'other'
      )
      """,
      "DROP TYPE asset_class"
    )

    execute(
      """
      CREATE TYPE asset_status AS ENUM (
        'active',
        'inactive'
      )
      """,
      "DROP TYPE asset_status"
    )

    # Create assets table
    create table(:assets, primary_key: false) do
      # Use Alpaca's UUID as primary key
      add :alpaca_id, :binary_id, primary_key: true

      # Essential fields extracted from Alpaca response
      add :symbol, :string, null: false
      add :name, :string, null: false
      add :exchange, :string
      add :class, :asset_class, null: false
      add :status, :asset_status, default: "active"
      add :tradable, :boolean, default: true

      # Store complete Alpaca response for debugging and future use
      # This preserves ALL data from Alpaca without loss
      add :meta, :map, null: false

      timestamps(type: :utc_datetime)
    end

    # Create indexes for common queries
    create unique_index(:assets, [:symbol])
    create index(:assets, [:exchange])
    create index(:assets, [:class])
    create index(:assets, [:status])
    create index(:assets, [:tradable])

    # Composite index for common query pattern: active + tradable assets
    create index(:assets, [:status, :tradable])
  end
end
