defmodule VolfefeMachine.Repo.Migrations.AddFundingSignalToWallets do
  use Ecto.Migration

  def change do
    alter table(:polymarket_wallets) do
      # Funding Signal fields for insider detection
      add :funded_at, :utc_datetime
      add :initial_deposit_amount, :decimal
      add :funding_to_first_trade_hours, :decimal
    end

    # Index for funding proximity analysis
    create index(:polymarket_wallets, [:funded_at])
    create index(:polymarket_wallets, [:funding_to_first_trade_hours])
  end
end
