defmodule VolfefeMachine.Repo.Migrations.CreateClassifications do
  use Ecto.Migration

  def change do
    create table(:classifications) do
      add :content_id, references(:contents, on_delete: :delete_all), null: false

      # Core classification data
      add :sentiment, :string, null: false
      add :confidence, :float, null: false
      add :model_version, :string, null: false

      # Flexible metadata storage for raw scores, processing info, errors
      add :meta, :map, default: %{}

      timestamps(type: :utc_datetime)
    end

    # Unique constraint: one classification per content
    create unique_index(:classifications, [:content_id])

    # Query optimization indexes
    create index(:classifications, [:sentiment])
    create index(:classifications, [:confidence])
    create index(:classifications, [:model_version])
  end
end
