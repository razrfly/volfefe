defmodule VolfefeMachine.Repo.Migrations.AddClassificationTimeIndex do
  use Ecto.Migration

  def change do
    # Add index on inserted_at for time-based queries
    # Enables efficient "last 24 hours" type queries
    create index(:classifications, [:inserted_at], name: :classifications_inserted_at_idx)
  end
end
