defmodule VolfefeMachine.Repo.Migrations.CreateModelClassifications do
  use Ecto.Migration

  def change do
    create table(:model_classifications) do
      add :content_id, references(:contents, on_delete: :delete_all), null: false
      add :model_id, :string, null: false
      add :model_version, :string, null: false
      add :sentiment, :string, null: false
      add :confidence, :float, null: false
      add :meta, :map, default: %{}

      timestamps(type: :utc_datetime)
    end

    # Indexes for common queries
    create index(:model_classifications, [:content_id])
    create index(:model_classifications, [:model_id])
    create index(:model_classifications, [:sentiment])
    create index(:model_classifications, [:inserted_at])

    # Unique constraint: one result per model per content
    create unique_index(:model_classifications, [:content_id, :model_id, :model_version],
                        name: :model_classifications_unique_idx)
  end
end
