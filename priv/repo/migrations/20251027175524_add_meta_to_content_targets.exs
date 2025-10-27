defmodule VolfefeMachine.Repo.Migrations.AddMetaToContentTargets do
  use Ecto.Migration

  def change do
    alter table(:content_targets) do
      add :meta, :map, default: %{}
    end
  end
end
