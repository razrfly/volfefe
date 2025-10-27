defmodule VolfefeMachine.Repo.Migrations.FixAssetsTableDesign do
  use Ecto.Migration

  def up do
    # Drop old broken table (safe - no foreign keys exist yet)
    drop table(:assets)

    # Create new table with proper design
    create table(:assets) do
      # Core asset data
      add :symbol, :string, null: false
      add :name, :string, null: false
      add :exchange, :string
      add :class, :asset_class, null: false
      add :status, :asset_status, default: "active"
      add :tradable, :boolean, default: true

      # Source tracking
      add :data_source, :string, null: false, default: "alpaca"
      add :alpaca_id, :binary_id  # Now nullable, just a unique identifier

      # Complete metadata from source
      add :meta, :map, null: false

      timestamps(type: :utc_datetime)
    end

    # Indexes for common queries
    create unique_index(:assets, [:symbol])
    create index(:assets, [:exchange])
    create index(:assets, [:class])
    create index(:assets, [:status])
    create index(:assets, [:tradable])
    create index(:assets, [:data_source])
    create index(:assets, [:status, :tradable])

    # CRITICAL: Unique constraint on alpaca_id when present
    # Allows NULL values but ensures uniqueness for non-NULL values
    create unique_index(:assets, [:alpaca_id],
                        where: "alpaca_id IS NOT NULL",
                        name: :assets_alpaca_id_unique)
  end

  def down do
    # Drop new table
    drop table(:assets)

    # Recreate old broken table for rollback
    create table(:assets, primary_key: false) do
      add :alpaca_id, :binary_id, primary_key: true
      add :symbol, :string, null: false
      add :name, :string, null: false
      add :exchange, :string
      add :class, :asset_class, null: false
      add :status, :asset_status, default: "active"
      add :tradable, :boolean, default: true
      add :meta, :map, null: false

      timestamps(type: :utc_datetime)
    end

    # Recreate old indexes
    create unique_index(:assets, [:symbol])
    create index(:assets, [:exchange])
    create index(:assets, [:class])
    create index(:assets, [:status])
    create index(:assets, [:tradable])
    create index(:assets, [:status, :tradable])
  end
end
