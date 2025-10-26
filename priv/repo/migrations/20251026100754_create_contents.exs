defmodule VolfefeMachine.Repo.Migrations.CreateContents do
  use Ecto.Migration

  def change do
    create table(:contents) do
      add :source_id, references(:sources, on_delete: :delete_all), null: false
      add :external_id, :string, null: false
      add :author, :string
      add :text, :text
      add :url, :string
      add :published_at, :utc_datetime
      add :classified, :boolean, default: false
      add :meta, :map

      timestamps(type: :utc_datetime)
    end

    create unique_index(:contents, [:source_id, :external_id])
    create index(:contents, [:source_id])
    create index(:contents, [:published_at])
    create index(:contents, [:classified])
  end
end
