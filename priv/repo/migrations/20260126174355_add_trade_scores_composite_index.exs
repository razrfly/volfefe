defmodule VolfefeMachine.Repo.Migrations.AddTradeScoresCompositeIndex do
  use Ecto.Migration

  @doc """
  Add composite indices for Phase 2 performance optimization.

  These indices optimize the pattern discovery queries which filter and sort
  on insider_probability and anomaly_score.
  """
  def change do
    # Composite index for discovery query ordering: ORDER BY insider_probability DESC, anomaly_score DESC
    # Filter: WHERE insider_probability IS NOT NULL AND anomaly_score >= threshold AND insider_probability >= threshold
    create_if_not_exists index(:polymarket_trade_scores, [:insider_probability, :anomaly_score],
      where: "insider_probability IS NOT NULL"
    )

    # Partial index for high-probability candidates (filtered scans)
    create_if_not_exists index(:polymarket_trade_scores, [:insider_probability],
      where: "insider_probability >= 0.5"
    )

    # Index on polymarket_trades for scoring queries (market_id + was_correct combo)
    create_if_not_exists index(:polymarket_trades, [:market_id, :was_correct],
      where: "was_correct IS NOT NULL"
    )
  end
end
