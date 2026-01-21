defmodule VolfefeMachine.Repo.Migrations.CreateInsiderReferenceCases do
  use Ecto.Migration

  def change do
    create table(:insider_reference_cases) do
      # Core identification
      add :case_name, :string, null: false
      add :event_date, :date
      add :platform, :string, null: false
      add :category, :string

      # Key metrics
      add :reported_profit, :decimal
      add :reported_bet_size, :decimal

      # Classification
      add :pattern_type, :string
      add :status, :string, default: "suspected"

      # Documentation
      add :description, :text
      add :source_urls, {:array, :string}, default: []

      timestamps()
    end

    create index(:insider_reference_cases, [:platform])
    create index(:insider_reference_cases, [:status])
    create index(:insider_reference_cases, [:pattern_type])
    create unique_index(:insider_reference_cases, [:case_name])
  end
end
