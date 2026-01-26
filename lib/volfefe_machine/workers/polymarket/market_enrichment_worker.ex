defmodule VolfefeMachine.Workers.Polymarket.MarketEnrichmentWorker do
  @moduledoc """
  Oban worker for enriching stub markets with metadata.

  Runs periodically to:
  1. Map stub market token_ids to real condition_ids via subgraph
  2. Merge stub markets into existing markets with full metadata
  3. Update condition_ids for unmapped stub markets

  ## Scheduling

  This worker runs every 30 minutes via Oban.Plugins.Cron.
  See config/config.exs for cron configuration.

  ## Manual Execution

      # Enqueue immediately
      %{}
      |> VolfefeMachine.Workers.Polymarket.MarketEnrichmentWorker.new()
      |> Oban.insert()

      # With options
      %{batch_size: 50, dry_run: true}
      |> VolfefeMachine.Workers.Polymarket.MarketEnrichmentWorker.new()
      |> Oban.insert()

  ## Job Arguments

    * `:batch_size` - Markets per batch (optional, default: 100)
    * `:max_markets` - Maximum markets to process (optional, default: all)
    * `:dry_run` - If true, log but don't change data (optional, default: false)
  """

  use Oban.Worker,
    queue: :polymarket,
    max_attempts: 3,
    unique: [period: 300]  # Prevent duplicate jobs within 5 minutes

  require Logger
  alias VolfefeMachine.Polymarket.MarketEnricher

  @impl Oban.Worker
  def perform(%Oban.Job{args: args}) do
    batch_size = Map.get(args, "batch_size", 100)
    max_markets = Map.get(args, "max_markets", :all)
    dry_run = Map.get(args, "dry_run", false)

    # Convert string "all" back to atom if needed
    max_markets = if max_markets == "all", do: :all, else: max_markets

    Logger.info("[MarketEnrichment] Starting enrichment job, batch_size=#{batch_size}, dry_run=#{dry_run}")

    # Get pre-enrichment stats
    pre_stats = MarketEnricher.get_enrichment_stats()
    Logger.info("[MarketEnrichment] Pre-stats: #{inspect(pre_stats)}")

    # Run enrichment
    case MarketEnricher.enrich_all_stub_markets(
      batch_size: batch_size,
      max_markets: max_markets,
      dry_run: dry_run
    ) do
      {:ok, results} ->
        # Get post-enrichment stats
        post_stats = MarketEnricher.get_enrichment_stats()

        Logger.info("[MarketEnrichment] Complete: merged=#{results.merged}, updated=#{results.updated}, unchanged=#{results.unchanged}, errors=#{results.errors}")
        Logger.info("[MarketEnrichment] Post-stats: #{inspect(post_stats)}")

        {:ok, %{
          results: results,
          pre_stats: pre_stats,
          post_stats: post_stats,
          completed_at: DateTime.utc_now() |> DateTime.to_iso8601()
        }}

      {:error, reason} ->
        Logger.error("[MarketEnrichment] Failed: #{inspect(reason)}")
        {:error, reason}
    end
  end
end
