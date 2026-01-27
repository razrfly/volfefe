defmodule VolfefeMachine.Repo.Migrations.CreateWatchedMarkets do
  use Ecto.Migration

  def change do
    create table(:watched_markets) do
      add :market_id, references(:polymarket_markets, on_delete: :delete_all), null: false
      add :notes, :text

      timestamps()
    end

    create unique_index(:watched_markets, [:market_id])
    create index(:watched_markets, [:inserted_at])
  end
end
