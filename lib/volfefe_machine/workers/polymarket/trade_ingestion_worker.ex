defmodule VolfefeMachine.Workers.Polymarket.TradeIngestionWorker do
  @moduledoc """
  Oban worker for automated trade ingestion from Polymarket.

  Runs on a scheduled interval to continuously ingest recent trades,
  ensuring wide net coverage across all categories.

  ## Scheduling

  This worker is scheduled via Oban.Plugins.Cron to run every 5 minutes.
  See config/config.exs for cron configuration.

  ## Manual Execution

      # Enqueue immediately
      %{}
      |> VolfefeMachine.Workers.Polymarket.TradeIngestionWorker.new()
      |> Oban.insert()

      # With custom limit
      %{limit: 5000}
      |> VolfefeMachine.Workers.Polymarket.TradeIngestionWorker.new()
      |> Oban.insert()

  ## Job Arguments

    * `:limit` - Maximum trades to ingest (optional, default: 2000)
  """

  use Oban.Worker,
    queue: :polymarket,
    max_attempts: 3,
    unique: [period: 60]  # Prevent duplicate jobs within 60 seconds

  require Logger
  alias VolfefeMachine.Polymarket

  @default_limit 2000

  @impl Oban.Worker
  def perform(%Oban.Job{args: args}) do
    limit = Map.get(args, "limit", @default_limit)

    Logger.info("[TradeIngestion] Starting ingestion, limit=#{limit}")

    case Polymarket.ingest_recent_trades(limit: limit) do
      {:ok, stats} ->
        Logger.info("[TradeIngestion] Complete: inserted=#{stats.inserted}, updated=#{stats.updated}, errors=#{stats.errors}")

        # Return stats for job meta
        {:ok, %{
          inserted: stats.inserted,
          updated: stats.updated,
          errors: stats.errors,
          completed_at: DateTime.utc_now() |> DateTime.to_iso8601()
        }}

      {:error, reason} ->
        Logger.error("[TradeIngestion] Failed: #{inspect(reason)}")
        {:error, reason}
    end
  end
end
