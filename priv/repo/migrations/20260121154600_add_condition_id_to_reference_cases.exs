defmodule VolfefeMachine.Repo.Migrations.AddConditionIdToReferenceCases do
  use Ecto.Migration

  def change do
    alter table(:insider_reference_cases) do
      # Market linkage for Polymarket cases
      add :condition_id, :string
      add :market_slug, :string
      add :market_question, :text

      # Data ingestion tracking
      add :trades_ingested_at, :utc_datetime
      add :trades_count, :integer, default: 0
    end

    # Index for looking up by condition_id
    create index(:insider_reference_cases, [:condition_id])
    create index(:insider_reference_cases, [:platform, :condition_id])
  end
end
