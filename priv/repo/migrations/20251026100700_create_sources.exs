defmodule VolfefeMachine.Repo.Migrations.CreateSources do
  use Ecto.Migration

  def change do
    create table(:sources) do
      add :name, :string, null: false
      add :adapter, :string, null: false
      add :base_url, :string
      add :last_fetched_at, :utc_datetime
      add :last_cursor, :string
      add :meta, :map, default: %{}
      add :enabled, :boolean, default: true

      timestamps(type: :utc_datetime)
    end

    create unique_index(:sources, [:name])
  end
end
