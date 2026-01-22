defmodule VolfefeMachine.Repo.Migrations.AddFundingProximityZscoreToTradeScores do
  use Ecto.Migration

  def change do
    alter table(:polymarket_trade_scores) do
      add :funding_proximity_zscore, :decimal
    end

    # Index for queries filtering by funding proximity score
    create index(:polymarket_trade_scores, [:funding_proximity_zscore])
  end
end
