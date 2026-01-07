defmodule VolfefeMachine.Workers.Polymarket.MarketSyncWorker do
  @moduledoc """
  Oban worker for automated market synchronization from Polymarket.

  Syncs market metadata, detects newly resolved markets, and triggers
  trade scoring for resolved markets.

  ## Scheduling

  This worker is scheduled via Oban.Plugins.Cron to run every hour.
  See config/config.exs for cron configuration.

  ## Manual Execution

      # Full sync with resolution checking
      %{check_resolutions: true}
      |> VolfefeMachine.Workers.Polymarket.MarketSyncWorker.new()
      |> Oban.insert()

      # Quick active-only sync
      %{active_only: true}
      |> VolfefeMachine.Workers.Polymarket.MarketSyncWorker.new()
      |> Oban.insert()

  ## Job Arguments

    * `:check_resolutions` - Check for newly resolved markets (default: true)
    * `:active_only` - Only sync active markets (default: false)
    * `:limit` - Maximum markets to sync (default: 1000)
  """

  use Oban.Worker,
    queue: :polymarket,
    max_attempts: 3,
    unique: [period: 300]  # Prevent duplicate jobs within 5 minutes

  require Logger
  import Ecto.Query
  alias VolfefeMachine.Repo
  alias VolfefeMachine.Polymarket
  alias VolfefeMachine.Polymarket.{Market, Trade}

  @default_limit 1000

  @impl Oban.Worker
  def perform(%Oban.Job{args: args}) do
    check_resolutions = Map.get(args, "check_resolutions", true)
    active_only = Map.get(args, "active_only", false)
    limit = Map.get(args, "limit", @default_limit)

    Logger.info("[MarketSync] Starting sync, check_resolutions=#{check_resolutions}, active_only=#{active_only}")

    results = %{
      markets_inserted: 0,
      markets_updated: 0,
      newly_resolved: 0,
      trades_scored: 0,
      errors: []
    }

    # Phase 1: Sync active markets
    results = sync_active_markets(results, limit)

    # Phase 2: Sync closed/resolved markets (unless active_only)
    results = if active_only do
      results
    else
      sync_resolved_markets(results, limit)
    end

    # Phase 3: Check for new resolutions and score trades
    results = if check_resolutions do
      check_and_score_resolutions(results)
    else
      results
    end

    Logger.info("[MarketSync] Complete: inserted=#{results.markets_inserted}, updated=#{results.markets_updated}, newly_resolved=#{results.newly_resolved}, scored=#{results.trades_scored}")

    if length(results.errors) > 0 do
      Logger.warning("[MarketSync] Errors: #{inspect(results.errors)}")
    end

    {:ok, Map.put(results, :completed_at, DateTime.utc_now() |> DateTime.to_iso8601())}
  end

  defp sync_active_markets(results, limit) do
    case Polymarket.sync_markets(limit: 100, max_markets: limit, include_closed: false) do
      {:ok, stats} ->
        %{results |
          markets_inserted: results.markets_inserted + stats.inserted,
          markets_updated: results.markets_updated + stats.updated
        }

      {:error, reason} ->
        %{results | errors: [{:active_sync, reason} | results.errors]}
    end
  end

  defp sync_resolved_markets(results, limit) do
    case Polymarket.sync_resolved_markets(max_markets: limit) do
      {:ok, stats} ->
        %{results |
          markets_inserted: results.markets_inserted + stats.synced,
          markets_updated: results.markets_updated + stats.resolved
        }

      {:error, reason} ->
        %{results | errors: [{:resolved_sync, reason} | results.errors]}
    end
  end

  defp check_and_score_resolutions(results) do
    # Find markets that are resolved but have trades without was_correct
    newly_resolved = Repo.all(
      from m in Market,
        join: t in Trade, on: t.market_id == m.id,
        where: not is_nil(m.resolved_outcome) and is_nil(t.was_correct),
        group_by: m.id,
        select: m
    )

    if length(newly_resolved) == 0 do
      Logger.info("[MarketSync] No newly resolved markets found")
      results
    else
      Logger.info("[MarketSync] Found #{length(newly_resolved)} newly resolved markets")

      # Calculate trade outcomes for each
      trades_updated = Enum.reduce(newly_resolved, 0, fn market, acc ->
        case Polymarket.calculate_trade_outcomes(market) do
          {:ok, %{updated: n}} -> acc + n
          _ -> acc
        end
      end)

      Logger.info("[MarketSync] Updated #{trades_updated} trades with was_correct/profit_loss")

      # Score the newly-resolved trades
      case Polymarket.score_all_trades(only_unscored: true) do
        {:ok, score_stats} ->
          Logger.info("[MarketSync] Scored #{score_stats.scored} trades")

          %{results |
            newly_resolved: length(newly_resolved),
            trades_scored: score_stats.scored
          }

        {:error, reason} ->
          %{results |
            newly_resolved: length(newly_resolved),
            errors: [{:scoring, reason} | results.errors]
          }
      end
    end
  end
end
