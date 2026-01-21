defmodule Mix.Tasks.Polymarket.Coverage do
  @moduledoc """
  Display trade coverage report across all categories.

  Shows how wide the net is being cast for insider detection.
  Essential for ensuring agnostic coverage across all market types.

  ## Usage

      # Full coverage report
      mix polymarket.coverage

      # Show alerts only
      mix polymarket.coverage --alerts

      # Detailed breakdown
      mix polymarket.coverage --verbose

  ## Options

      --alerts    Show only coverage alerts/warnings
      --verbose   Show detailed breakdown including market lists

  ## Examples

      $ mix polymarket.coverage

      ═══════════════════════════════════════════════════════════════
      POLYMARKET COVERAGE REPORT
      ═══════════════════════════════════════════════════════════════

      CATEGORY COVERAGE
      ┌──────────────┬─────────┬─────────┬──────────┬───────────┐
      │ Category     │ Markets │ Trades  │ Scored   │ Last Trade│
      ├──────────────┼─────────┼─────────┼──────────┼───────────┤
      │ politics     │ 45/120  │ 12,340  │ 8,200    │ 2m ago    │
      │ crypto       │ 23/89   │ 5,670   │ 3,100    │ 5m ago    │
      │ sports       │ 12/234  │ 1,234   │ 890      │ 12m ago   │
      │ science      │ 3/15    │ 456     │ 200      │ 2h ago ⚠️  │
      │ corporate    │ 0/8     │ 0       │ 0        │ never ❌   │
      │ other        │ 8/45    │ 2,100   │ 1,500    │ 8m ago    │
      └──────────────┴─────────┴─────────┴──────────┴───────────┘

      HEALTH METRICS
      ├─ Overall Coverage: 91/511 markets (17.8%)
      ├─ Category Coverage: 5/6 categories (83.3%)
      ├─ Stale Categories: 1 (science > 1h)
      ├─ Missing Categories: 1 (corporate)
      └─ Candidate Diversity: 4 categories represented

      ⚠️  ALERTS:
      - corporate: No trades captured
      - science: Stale data (>1h) - consider more frequent ingestion
  """

  use Mix.Task
  require Logger
  import Ecto.Query
  alias VolfefeMachine.Repo
  alias VolfefeMachine.Polymarket.{Market, Trade, TradeScore, InvestigationCandidate}

  @shortdoc "Display trade coverage report"

  @all_categories ~w(politics corporate legal crypto sports entertainment science other)a
  @staleness_threshold_seconds 3600  # 1 hour

  @impl Mix.Task
  def run(args) do
    Mix.Task.run("app.start")

    {opts, _, _} = OptionParser.parse(args,
      switches: [
        alerts: :boolean,
        verbose: :boolean
      ],
      aliases: [a: :alerts, v: :verbose]
    )

    print_header()

    coverage = calculate_coverage()

    unless opts[:alerts] do
      print_category_table(coverage)
      print_health_metrics(coverage)
    end

    print_alerts(coverage)

    if opts[:verbose] do
      print_verbose_details(coverage)
    end

    print_footer()
  end

  defp calculate_coverage do
    # Get market counts by category
    market_counts = Repo.all(
      from m in Market,
        group_by: m.category,
        select: {m.category, count(m.id)}
    ) |> Enum.into(%{})

    # Get markets with trades by category
    markets_with_trades = Repo.all(
      from t in Trade,
        join: m in Market, on: t.market_id == m.id,
        group_by: m.category,
        select: {m.category, count(t.market_id, :distinct)}
    ) |> Enum.into(%{})

    # Get trade counts by category
    trade_counts = Repo.all(
      from t in Trade,
        join: m in Market, on: t.market_id == m.id,
        group_by: m.category,
        select: {m.category, count(t.id)}
    ) |> Enum.into(%{})

    # Get scored trade counts by category
    scored_counts = Repo.all(
      from t in Trade,
        join: m in Market, on: t.market_id == m.id,
        join: s in TradeScore, on: s.trade_id == t.id,
        group_by: m.category,
        select: {m.category, count(t.id)}
    ) |> Enum.into(%{})

    # Get last trade timestamp by category
    last_trades = Repo.all(
      from t in Trade,
        join: m in Market, on: t.market_id == m.id,
        group_by: m.category,
        select: {m.category, max(t.inserted_at)}
    ) |> Enum.into(%{})

    # Get candidate category diversity
    candidate_categories = Repo.all(
      from c in InvestigationCandidate,
        join: m in Market, on: c.market_id == m.id,
        where: c.status != "cleared",
        group_by: m.category,
        select: m.category
    )

    # Build category details
    categories = Enum.map(@all_categories, fn cat ->
      total_markets = Map.get(market_counts, cat, 0)
      markets_with = Map.get(markets_with_trades, cat, 0)
      trades = Map.get(trade_counts, cat, 0)
      scored = Map.get(scored_counts, cat, 0)
      last_trade = Map.get(last_trades, cat)

      %{
        category: cat,
        total_markets: total_markets,
        markets_with_trades: markets_with,
        trades: trades,
        scored: scored,
        last_trade: last_trade,
        staleness: calculate_staleness(last_trade),
        is_stale: is_stale?(last_trade),
        is_missing: trades == 0
      }
    end)

    # Calculate totals
    total_markets = Enum.sum(Map.values(market_counts))
    total_with_trades = Enum.sum(Map.values(markets_with_trades))
    total_trades = Enum.sum(Map.values(trade_counts))
    total_scored = Enum.sum(Map.values(scored_counts))

    categories_with_data = Enum.count(categories, & &1.trades > 0)
    stale_categories = Enum.filter(categories, & &1.is_stale && &1.trades > 0)
    missing_categories = Enum.filter(categories, & &1.is_missing && &1.total_markets > 0)

    %{
      categories: categories,
      total_markets: total_markets,
      total_with_trades: total_with_trades,
      total_trades: total_trades,
      total_scored: total_scored,
      categories_with_data: categories_with_data,
      stale_categories: stale_categories,
      missing_categories: missing_categories,
      candidate_categories: candidate_categories
    }
  end

  defp calculate_staleness(nil), do: nil
  defp calculate_staleness(last_trade) do
    DateTime.diff(DateTime.utc_now(), last_trade, :second)
  end

  defp is_stale?(nil), do: false
  defp is_stale?(last_trade) do
    DateTime.diff(DateTime.utc_now(), last_trade, :second) > @staleness_threshold_seconds
  end

  defp print_category_table(coverage) do
    Mix.shell().info("CATEGORY COVERAGE")
    Mix.shell().info("┌──────────────┬──────────────┬──────────┬──────────┬────────────┐")
    Mix.shell().info("│ Category     │ Markets      │ Trades   │ Scored   │ Last Trade │")
    Mix.shell().info("├──────────────┼──────────────┼──────────┼──────────┼────────────┤")

    Enum.each(coverage.categories, fn cat ->
      name = String.pad_trailing(to_string(cat.category), 12)
      markets = String.pad_trailing("#{cat.markets_with_trades}/#{cat.total_markets}", 12)
      trades = String.pad_trailing(format_number(cat.trades), 8)
      scored = String.pad_trailing(format_number(cat.scored), 8)
      last = format_last_trade(cat.last_trade, cat.is_stale, cat.is_missing)

      Mix.shell().info("│ #{name} │ #{markets} │ #{trades} │ #{scored} │ #{last} │")
    end)

    Mix.shell().info("└──────────────┴──────────────┴──────────┴──────────┴────────────┘")
    Mix.shell().info("")
  end

  defp print_health_metrics(coverage) do
    market_pct = if coverage.total_markets > 0 do
      Float.round(coverage.total_with_trades / coverage.total_markets * 100, 1)
    else
      0.0
    end

    category_pct = Float.round(coverage.categories_with_data / length(@all_categories) * 100, 1)

    Mix.shell().info("HEALTH METRICS")
    Mix.shell().info("├─ Market Coverage: #{coverage.total_with_trades}/#{coverage.total_markets} (#{market_pct}%)")
    Mix.shell().info("├─ Category Coverage: #{coverage.categories_with_data}/#{length(@all_categories)} (#{category_pct}%)")
    Mix.shell().info("├─ Stale Categories: #{length(coverage.stale_categories)}")
    Mix.shell().info("├─ Missing Categories: #{length(coverage.missing_categories)}")
    Mix.shell().info("├─ Total Trades: #{format_number(coverage.total_trades)}")
    Mix.shell().info("├─ Scored Trades: #{format_number(coverage.total_scored)}")
    Mix.shell().info("└─ Candidate Diversity: #{length(coverage.candidate_categories)} categories")
    Mix.shell().info("")
  end

  defp print_alerts(coverage) do
    alerts = []

    # Missing categories with markets
    alerts = alerts ++ Enum.map(coverage.missing_categories, fn cat ->
      {:error, "#{cat.category}: No trades captured (#{cat.total_markets} markets available)"}
    end)

    # Stale categories
    alerts = alerts ++ Enum.map(coverage.stale_categories, fn cat ->
      hours = div(cat.staleness, 3600)
      {:warning, "#{cat.category}: Stale data (#{hours}h since last trade)"}
    end)

    # Low coverage warning
    alerts = if coverage.total_with_trades < coverage.total_markets * 0.1 do
      [{:warning, "Low market coverage (<10%) - run: mix polymarket.ingest --all-active"} | alerts]
    else
      alerts
    end

    # Single category concentration
    alerts = if coverage.categories_with_data == 1 do
      [{:error, "Narrow net: All trades from single category!"} | alerts]
    else
      alerts
    end

    if length(alerts) > 0 do
      Mix.shell().info("⚠️  ALERTS:")
      Enum.each(alerts, fn
        {:error, msg} -> Mix.shell().error("  ❌ #{msg}")
        {:warning, msg} -> Mix.shell().info("  ⚠️  #{msg}")
      end)
      Mix.shell().info("")
    else
      Mix.shell().info("✅ Coverage looks healthy!")
      Mix.shell().info("")
    end
  end

  defp print_verbose_details(coverage) do
    Mix.shell().info("DETAILED BREAKDOWN")
    Mix.shell().info("")

    Enum.each(coverage.categories, fn cat ->
      if cat.trades > 0 do
        Mix.shell().info("#{cat.category}:")
        Mix.shell().info("  Markets with trades: #{cat.markets_with_trades}")
        Mix.shell().info("  Total trades: #{format_number(cat.trades)}")
        Mix.shell().info("  Scored: #{format_number(cat.scored)} (#{score_pct(cat)}%)")
        Mix.shell().info("  Unscored: #{format_number(cat.trades - cat.scored)}")
        Mix.shell().info("")
      end
    end)
  end

  defp score_pct(%{trades: 0}), do: 0
  defp score_pct(%{trades: trades, scored: scored}) do
    Float.round(scored / trades * 100, 1)
  end

  defp format_last_trade(nil, _, true), do: String.pad_trailing("never ❌", 10)
  defp format_last_trade(nil, _, _), do: String.pad_trailing("never", 10)
  defp format_last_trade(dt, is_stale, _) do
    ago = format_time_ago(dt)
    indicator = if is_stale, do: " ⚠️", else: ""
    String.pad_trailing("#{ago}#{indicator}", 10)
  end

  defp format_time_ago(dt) do
    seconds = DateTime.diff(DateTime.utc_now(), dt, :second)

    cond do
      seconds < 60 -> "#{seconds}s ago"
      seconds < 3600 -> "#{div(seconds, 60)}m ago"
      seconds < 86400 -> "#{div(seconds, 3600)}h ago"
      true -> "#{div(seconds, 86400)}d ago"
    end
  end

  defp format_number(n) when is_integer(n) do
    n
    |> Integer.to_string()
    |> String.reverse()
    |> String.replace(~r/(\d{3})(?=\d)/, "\\1,")
    |> String.reverse()
  end
  defp format_number(n), do: "#{n}"

  defp print_header do
    Mix.shell().info("")
    Mix.shell().info(String.duplicate("═", 65))
    Mix.shell().info("POLYMARKET COVERAGE REPORT")
    Mix.shell().info(String.duplicate("═", 65))
    Mix.shell().info("")
  end

  defp print_footer do
    Mix.shell().info(String.duplicate("─", 65))
    Mix.shell().info("Ingest trades: mix polymarket.ingest")
    Mix.shell().info("Sync markets: mix polymarket.sync")
    Mix.shell().info("")
  end
end
