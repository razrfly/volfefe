defmodule VolfefeMachine.Repo.Migrations.CreateInvestigationNotes do
  use Ecto.Migration

  def change do
    create table(:polymarket_investigation_notes) do
      add :wallet_address, :string, null: false
      add :note_text, :text, null: false
      add :author, :string, default: "admin"
      add :note_type, :string, default: "general"  # general, evidence, action, dismissal

      timestamps(type: :utc_datetime)
    end

    create index(:polymarket_investigation_notes, [:wallet_address])
    create index(:polymarket_investigation_notes, [:inserted_at])
  end
end
