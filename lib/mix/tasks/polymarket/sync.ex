defmodule Mix.Tasks.Polymarket.Sync do
  @moduledoc """
  Sync markets from Polymarket API.

  Discovers new markets, updates metadata, and detects resolution changes.
  Essential for maintaining wide-net coverage across all categories.

  ## Usage

      # Sync all markets (active + recently closed)
      mix polymarket.sync

      # Sync only active markets
      mix polymarket.sync --active

      # Include all closed/resolved markets
      mix polymarket.sync --closed

      # Check for newly resolved markets and trigger scoring
      mix polymarket.sync --check-resolutions

      # Full sync with resolution checking
      mix polymarket.sync --full

  ## Options

      --active             Sync only active markets
      --closed             Include closed/resolved markets
      --check-resolutions  Detect newly resolved markets and score their trades
      --full               Full sync: active + closed + resolution check + scoring
      --limit N            Maximum markets to sync (default: 1000)
      --verbose            Show detailed output

  ## Resolution Detection

  When using --check-resolutions or --full, the task will:
  1. Identify markets that just resolved (have resolution but unscored trades)
  2. Calculate was_correct and profit_loss for their trades
  3. Score the newly-resolved trades
  4. Report which markets became scorable

  ## Examples

      $ mix polymarket.sync --full

      ═══════════════════════════════════════════════════════════════
      POLYMARKET MARKET SYNC
      ═══════════════════════════════════════════════════════════════

      Phase 1: Syncing active markets...
      ✅ Active: 234 inserted, 156 updated

      Phase 2: Syncing closed markets...
      ✅ Closed: 45 inserted, 89 updated

      Phase 3: Checking for new resolutions...
      Found 3 newly resolved markets:
        - Will XRP reach $3 by January 10?
        - Leicester City FC win on 2026-01-05?
        - Fed rate decision January 2026

      Phase 4: Calculating trade outcomes...
      ✅ Updated 456 trades with was_correct/profit_loss

      Phase 5: Scoring newly-resolved trades...
      ✅ Scored 456 trades

      ═══════════════════════════════════════════════════════════════
      SYNC COMPLETE
      ├─ Markets synced: 524
      ├─ Newly resolved: 3
      ├─ Trades updated: 456
      └─ Trades scored: 456
  """

  use Mix.Task
  require Logger
  import Ecto.Query
  alias VolfefeMachine.Repo
  alias VolfefeMachine.Polymarket
  alias VolfefeMachine.Polymarket.{Market, Trade}

  @shortdoc "Sync markets from Polymarket"

  @impl Mix.Task
  def run(args) do
    Mix.Task.run("app.start")

    {opts, _, _} = OptionParser.parse(args,
      switches: [
        active: :boolean,
        closed: :boolean,
        check_resolutions: :boolean,
        full: :boolean,
        limit: :integer,
        verbose: :boolean
      ],
      aliases: [l: :limit, v: :verbose]
    )

    print_header()

    results = %{
      active_inserted: 0,
      active_updated: 0,
      closed_inserted: 0,
      closed_updated: 0,
      newly_resolved: 0,
      trades_updated: 0,
      trades_scored: 0,
      errors: 0
    }

    # Determine what to sync
    do_active = opts[:active] || opts[:full] || (!opts[:closed] && !opts[:check_resolutions])
    do_closed = opts[:closed] || opts[:full]
    do_resolutions = opts[:check_resolutions] || opts[:full]

    limit = opts[:limit] || 1000
    verbose = opts[:verbose] || false

    results =
      results
      |> maybe_sync_active(do_active, limit, verbose)
      |> maybe_sync_closed(do_closed, limit, verbose)
      |> maybe_check_resolutions(do_resolutions, verbose)

    print_summary(results)
    print_footer()
  end

  defp maybe_sync_active(results, do_active, _limit, _verbose) when do_active != true, do: results
  defp maybe_sync_active(results, true, limit, verbose) do
    Mix.shell().info("Phase 1: Syncing active markets...")

    case Polymarket.sync_markets(limit: 100, max_markets: limit, include_closed: false) do
      {:ok, stats} ->
        Mix.shell().info("✅ Active: #{stats.inserted} inserted, #{stats.updated} updated")

        if verbose && stats.inserted > 0 do
          show_category_breakdown()
        end

        Mix.shell().info("")
        %{results |
          active_inserted: stats.inserted,
          active_updated: stats.updated
        }

      {:error, reason} ->
        Mix.shell().error("❌ Active sync failed: #{inspect(reason)}")
        %{results | errors: results.errors + 1}
    end
  end

  defp maybe_sync_closed(results, do_closed, _limit, _verbose) when do_closed != true, do: results
  defp maybe_sync_closed(results, true, limit, verbose) do
    Mix.shell().info("Phase 2: Syncing closed/resolved markets...")

    case Polymarket.sync_resolved_markets(max_markets: limit) do
      {:ok, stats} ->
        Mix.shell().info("✅ Closed: #{stats.synced} synced, #{stats.resolved} with resolution")

        if verbose do
          Mix.shell().info("   Event-based: #{stats.event_based}")
        end

        Mix.shell().info("")
        %{results |
          closed_inserted: stats.synced,
          closed_updated: stats.resolved
        }

      {:error, reason} ->
        Mix.shell().error("❌ Closed sync failed: #{inspect(reason)}")
        %{results | errors: results.errors + 1}
    end
  end

  defp maybe_check_resolutions(results, do_check, _verbose) when do_check != true, do: results
  defp maybe_check_resolutions(results, true, verbose) do
    Mix.shell().info("Phase 3: Checking for newly resolved markets...")

    # Find markets that are resolved but have trades without was_correct
    newly_resolved_markets = find_newly_resolved_markets()

    if length(newly_resolved_markets) == 0 do
      Mix.shell().info("   No newly resolved markets found")
      Mix.shell().info("")
      results
    else
      Mix.shell().info("Found #{length(newly_resolved_markets)} newly resolved markets:")

      if verbose do
        Enum.take(newly_resolved_markets, 10) |> Enum.each(fn m ->
          Mix.shell().info("  - #{truncate(m.question, 50)}")
        end)
        if length(newly_resolved_markets) > 10 do
          Mix.shell().info("  ... and #{length(newly_resolved_markets) - 10} more")
        end
      end

      Mix.shell().info("")

      # Calculate trade outcomes for each
      Mix.shell().info("Phase 4: Calculating trade outcomes...")

      trades_updated = Enum.reduce(newly_resolved_markets, 0, fn market, acc ->
        {:ok, %{updated: n}} = Polymarket.calculate_trade_outcomes(market)
        acc + n
      end)

      Mix.shell().info("✅ Updated #{trades_updated} trades with was_correct/profit_loss")
      Mix.shell().info("")

      # Score the newly-resolved trades
      Mix.shell().info("Phase 5: Scoring newly-resolved trades...")

      {:ok, score_stats} = Polymarket.score_all_trades(only_unscored: true)
      Mix.shell().info("✅ Scored #{score_stats.scored} trades")
      Mix.shell().info("")

      %{results |
        newly_resolved: length(newly_resolved_markets),
        trades_updated: trades_updated,
        trades_scored: score_stats.scored
      }
    end
  end

  defp find_newly_resolved_markets do
    # Markets that are resolved but have trades without was_correct set
    Repo.all(
      from m in Market,
        join: t in Trade, on: t.market_id == m.id,
        where: not is_nil(m.resolved_outcome) and is_nil(t.was_correct),
        group_by: m.id,
        select: m
    )
  end

  defp show_category_breakdown do
    # Get counts by category for all markets
    category_counts = Repo.all(
      from m in Market,
        group_by: m.category,
        select: {m.category, count(m.id)},
        order_by: [desc: count(m.id)]
    )

    total = Enum.reduce(category_counts, 0, fn {_, c}, acc -> acc + c end)

    Mix.shell().info("CATEGORY DISTRIBUTION (#{total} markets)")
    Enum.each(category_counts, fn {cat, count} ->
      pct = Float.round(count / total * 100, 1)
      bar_len = round(count / total * 20)
      bar = String.duplicate("█", bar_len) <> String.duplicate("░", 20 - bar_len)
      Mix.shell().info("  #{String.pad_trailing(to_string(cat || "nil"), 12)} #{bar} #{count} (#{pct}%)")
    end)
    Mix.shell().info("")
  end

  defp print_header do
    Mix.shell().info("")
    Mix.shell().info(String.duplicate("═", 65))
    Mix.shell().info("POLYMARKET MARKET SYNC")
    Mix.shell().info(String.duplicate("═", 65))
    Mix.shell().info("")
  end

  defp print_summary(results) do
    Mix.shell().info(String.duplicate("═", 65))
    Mix.shell().info("SYNC COMPLETE")

    total_markets = results.active_inserted + results.active_updated +
                    results.closed_inserted + results.closed_updated

    Mix.shell().info("├─ Markets synced: #{total_markets}")
    Mix.shell().info("├─ Newly resolved: #{results.newly_resolved}")
    Mix.shell().info("├─ Trades updated: #{results.trades_updated}")
    Mix.shell().info("└─ Trades scored: #{results.trades_scored}")

    if results.errors > 0 do
      Mix.shell().info("")
      Mix.shell().error("⚠️  #{results.errors} errors occurred during sync")
    end

    Mix.shell().info("")

    # Show category distribution
    show_category_breakdown()
  end

  defp print_footer do
    Mix.shell().info(String.duplicate("─", 65))
    Mix.shell().info("Run discovery: mix polymarket.discover")
    Mix.shell().info("")
  end

  defp truncate(nil, _), do: ""
  defp truncate(str, max_length) when is_binary(str) do
    if String.length(str) > max_length do
      String.slice(str, 0, max_length) <> "..."
    else
      str
    end
  end
end
