defmodule VolfefeMachine.Repo.Migrations.AddMentionTextToContentTargets do
  use Ecto.Migration

  def change do
    alter table(:content_targets) do
      add :mention_text, :string
    end

    create index(:content_targets, [:mention_text])
  end
end
