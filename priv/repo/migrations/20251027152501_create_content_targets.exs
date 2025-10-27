defmodule VolfefeMachine.Repo.Migrations.CreateContentTargets do
  use Ecto.Migration

  def up do
    # Create extraction method enum
    create_extraction_method_enum()

    # Create content_targets table
    create table(:content_targets) do
      # Foreign keys - CRITICAL: asset_id references assets.id (auto-increment), NOT alpaca_id
      add :content_id, references(:contents, on_delete: :delete_all), null: false
      add :asset_id, references(:assets, on_delete: :delete_all), null: false

      # Extraction metadata
      add :extraction_method, :extraction_method, null: false, default: "manual"
      add :confidence, :float, null: false, default: 1.0
      add :context, :text  # Text snippet where asset was mentioned

      timestamps(type: :utc_datetime)
    end

    # Indexes for performance
    create index(:content_targets, [:content_id])
    create index(:content_targets, [:asset_id])
    create index(:content_targets, [:extraction_method])

    # Unique constraint: one asset can only be mentioned once per content
    create unique_index(:content_targets, [:content_id, :asset_id],
                        name: :content_targets_content_asset_unique)
  end

  def down do
    drop table(:content_targets)
    drop_extraction_method_enum()
  end

  # Private functions

  defp create_extraction_method_enum do
    execute """
    CREATE TYPE extraction_method AS ENUM (
      'manual',
      'ner',
      'regex',
      'keyword',
      'ai'
    )
    """
  end

  defp drop_extraction_method_enum do
    execute "DROP TYPE extraction_method"
  end
end
