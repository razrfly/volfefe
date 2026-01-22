defmodule VolfefeMachine.Repo.Migrations.AddDiscoveredFieldsToInsiderReferenceCases do
  use Ecto.Migration

  def change do
    alter table(:insider_reference_cases) do
      # Wallets flagged as suspicious by analysis
      add :discovered_wallets, {:array, :map}, default: []

      # All candidate condition_ids found during discovery
      add :discovered_condition_ids, {:array, :string}, default: []

      # Notes from analysis process
      add :analysis_notes, :text

      # When discovery was last run
      add :discovery_run_at, :utc_datetime

      # Discovery metadata (window, trade count, etc.)
      add :discovery_meta, :map, default: %{}
    end
  end
end
