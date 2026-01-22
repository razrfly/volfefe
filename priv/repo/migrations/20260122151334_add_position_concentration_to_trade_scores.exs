defmodule VolfefeMachine.Repo.Migrations.AddPositionConcentrationToTradeScores do
  use Ecto.Migration

  def change do
    alter table(:polymarket_trade_scores) do
      # Position concentration: How directional is this wallet's activity on this market?
      # High concentration (all one side) may indicate insider knowledge
      add :position_concentration_zscore, :decimal
    end
  end
end
