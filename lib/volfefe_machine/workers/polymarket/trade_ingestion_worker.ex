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
    hours = Map.get(args, "hours", 24)

    Logger.info("[TradeIngestion] Starting subgraph ingestion, limit=#{limit}, hours=#{hours}")

    # Use subgraph-based ingestion with token-based auto-discovery
    # Skip slow subgraph mapping - we auto-create stub markets for unknown tokens
    case Polymarket.ingest_trades_via_subgraph(limit: limit, hours: hours, build_subgraph_mapping: false) do
      {:ok, stats} ->
        Logger.info("[TradeIngestion] Complete: inserted=#{stats.inserted}, updated=#{stats.updated}, errors=#{stats.errors}, unmapped=#{stats.unmapped}")

        # Return stats for job meta
        {:ok, %{
          inserted: stats.inserted,
          updated: stats.updated,
          errors: stats.errors,
          unmapped: stats.unmapped,
          completed_at: DateTime.utc_now() |> DateTime.to_iso8601()
        }}

      {:error, :rate_limited} ->
        # Snooze for 5 minutes when rate limited by Goldsky
        Logger.warning("[TradeIngestion] Rate limited by subgraph, snoozing for 5 minutes")
        {:snooze, 300}

      {:error, reason} ->
        # Check for string-based rate limit errors
        if is_binary(reason) and String.contains?(reason, "rate") do
          Logger.warning("[TradeIngestion] Rate limited (string match), snoozing for 5 minutes")
          {:snooze, 300}
        else
          Logger.error("[TradeIngestion] Failed: #{inspect(reason)}")
          {:error, reason}
        end
    end
  end
end
