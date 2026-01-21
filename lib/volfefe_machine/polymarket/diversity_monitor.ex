defmodule VolfefeMachine.Polymarket.DiversityMonitor do
  @moduledoc """
  Monitors trade coverage diversity across categories.

  Detects when the net narrows (too much concentration) or
  categories become stale (no recent trades).

  ## Thresholds

    * Staleness: Category is stale if no trades in last hour
    * Concentration: Alert if >80% of trades from one category
    * Missing: Alert if category has markets but no trades
    * Minimum Coverage: At least 3 categories should have data

  ## Usage

      # Get full coverage report
      DiversityMonitor.get_coverage()

      # Check for alerts only
      DiversityMonitor.check_alerts()

      # Get specific metrics
      DiversityMonitor.category_health(:crypto)
  """

  require Logger
  import Ecto.Query
  alias VolfefeMachine.Repo
  alias VolfefeMachine.Polymarket.{Market, Trade, TradeScore, InvestigationCandidate}

  @all_categories ~w(politics corporate legal crypto sports entertainment science other)a

  # Configurable thresholds
  @staleness_threshold_seconds 3600       # 1 hour
  @concentration_threshold 0.8            # 80% from one category is concerning
  @min_category_coverage 3                # At least 3 categories with data
  @critical_staleness_seconds 86400       # 24 hours is critical

  @doc """
  Returns comprehensive coverage metrics for all categories.
  """
  def get_coverage do
    market_counts = get_market_counts()
    markets_with_trades = get_markets_with_trades()
    trade_counts = get_trade_counts()
    scored_counts = get_scored_counts()
    last_trades = get_last_trades()
    candidate_categories = get_candidate_categories()

    categories = build_category_details(
      market_counts, markets_with_trades, trade_counts,
      scored_counts, last_trades
    )

    total_markets = Enum.sum(Map.values(market_counts))
    total_with_trades = Enum.sum(Map.values(markets_with_trades))
    total_trades = Enum.sum(Map.values(trade_counts))
    total_scored = Enum.sum(Map.values(scored_counts))

    categories_with_data = Enum.count(categories, & &1.trades > 0)
    stale_categories = Enum.filter(categories, & &1.is_stale && &1.trades > 0)
    missing_categories = Enum.filter(categories, & &1.is_missing && &1.total_markets > 0)
    critical_categories = Enum.filter(categories, & &1.is_critical)

    # Calculate concentration
    {top_category, concentration} = calculate_concentration(trade_counts, total_trades)

    %{
      categories: categories,
      total_markets: total_markets,
      total_with_trades: total_with_trades,
      total_trades: total_trades,
      total_scored: total_scored,
      categories_with_data: categories_with_data,
      stale_categories: stale_categories,
      missing_categories: missing_categories,
      critical_categories: critical_categories,
      candidate_categories: candidate_categories,
      top_category: top_category,
      concentration: concentration,
      is_concentrated: concentration > @concentration_threshold,
      health_score: calculate_health_score(categories, concentration, categories_with_data)
    }
  end

  @doc """
  Checks coverage and returns list of alerts if any issues detected.

  Returns `{:ok, []}` if healthy, `{:alerts, list}` if issues found.
  """
  def check_alerts do
    coverage = get_coverage()
    alerts = build_alerts(coverage)

    if alerts == [] do
      {:ok, []}
    else
      {:alerts, alerts}
    end
  end

  @doc """
  Runs diversity check and logs any alerts found.

  Returns map with check results and any alerts triggered.
  """
  def run_check do
    coverage = get_coverage()
    alerts = build_alerts(coverage)

    # Log alerts
    Enum.each(alerts, fn alert ->
      case alert.severity do
        :critical -> Logger.error("[DiversityMonitor] #{alert.message}")
        :warning -> Logger.warning("[DiversityMonitor] #{alert.message}")
        :info -> Logger.info("[DiversityMonitor] #{alert.message}")
      end
    end)

    # Log summary
    if alerts == [] do
      Logger.info("[DiversityMonitor] Coverage healthy - #{coverage.categories_with_data}/#{length(@all_categories)} categories active, health_score=#{coverage.health_score}")
    else
      Logger.warning("[DiversityMonitor] #{length(alerts)} alerts - health_score=#{coverage.health_score}")
    end

    %{
      checked_at: DateTime.utc_now(),
      health_score: coverage.health_score,
      categories_active: coverage.categories_with_data,
      total_trades: coverage.total_trades,
      concentration: Float.round(coverage.concentration * 100, 1),
      alerts: alerts
    }
  end

  @doc """
  Gets health status for a specific category.
  """
  def category_health(category) when is_atom(category) do
    coverage = get_coverage()

    case Enum.find(coverage.categories, & &1.category == category) do
      nil -> {:error, :not_found}
      cat -> {:ok, cat}
    end
  end

  @doc """
  Returns health summary suitable for dashboards/APIs.
  """
  def health_summary do
    coverage = get_coverage()
    alerts = build_alerts(coverage)

    %{
      healthy: alerts == [],
      health_score: coverage.health_score,
      categories_active: coverage.categories_with_data,
      categories_total: length(@all_categories),
      total_markets: coverage.total_markets,
      markets_with_trades: coverage.total_with_trades,
      total_trades: coverage.total_trades,
      scored_trades: coverage.total_scored,
      concentration: %{
        top_category: coverage.top_category,
        percentage: Float.round(coverage.concentration * 100, 1),
        is_concerning: coverage.is_concentrated
      },
      stale_count: length(coverage.stale_categories),
      missing_count: length(coverage.missing_categories),
      critical_count: length(coverage.critical_categories),
      alert_count: length(alerts),
      checked_at: DateTime.utc_now()
    }
  end

  # Private functions

  defp get_market_counts do
    Repo.all(
      from m in Market,
        group_by: m.category,
        select: {m.category, count(m.id)}
    ) |> Enum.into(%{})
  end

  defp get_markets_with_trades do
    Repo.all(
      from t in Trade,
        join: m in Market, on: t.market_id == m.id,
        group_by: m.category,
        select: {m.category, count(t.market_id, :distinct)}
    ) |> Enum.into(%{})
  end

  defp get_trade_counts do
    Repo.all(
      from t in Trade,
        join: m in Market, on: t.market_id == m.id,
        group_by: m.category,
        select: {m.category, count(t.id)}
    ) |> Enum.into(%{})
  end

  defp get_scored_counts do
    Repo.all(
      from t in Trade,
        join: m in Market, on: t.market_id == m.id,
        join: s in TradeScore, on: s.trade_id == t.id,
        group_by: m.category,
        select: {m.category, count(t.id)}
    ) |> Enum.into(%{})
  end

  defp get_last_trades do
    Repo.all(
      from t in Trade,
        join: m in Market, on: t.market_id == m.id,
        group_by: m.category,
        select: {m.category, max(t.inserted_at)}
    ) |> Enum.into(%{})
  end

  defp get_candidate_categories do
    Repo.all(
      from c in InvestigationCandidate,
        join: m in Market, on: c.market_id == m.id,
        where: c.status != "cleared",
        group_by: m.category,
        select: m.category
    )
  end

  defp build_category_details(market_counts, markets_with_trades, trade_counts, scored_counts, last_trades) do
    Enum.map(@all_categories, fn cat ->
      total_markets = Map.get(market_counts, cat, 0)
      markets_with = Map.get(markets_with_trades, cat, 0)
      trades = Map.get(trade_counts, cat, 0)
      scored = Map.get(scored_counts, cat, 0)
      last_trade = Map.get(last_trades, cat)
      staleness = calculate_staleness(last_trade)

      %{
        category: cat,
        total_markets: total_markets,
        markets_with_trades: markets_with,
        trades: trades,
        scored: scored,
        last_trade: last_trade,
        staleness_seconds: staleness,
        is_stale: staleness != nil && staleness > @staleness_threshold_seconds,
        is_critical: staleness != nil && staleness > @critical_staleness_seconds,
        is_missing: trades == 0 && total_markets > 0
      }
    end)
  end

  defp calculate_staleness(nil), do: nil
  defp calculate_staleness(last_trade) do
    DateTime.diff(DateTime.utc_now(), last_trade, :second)
  end

  defp calculate_concentration(_trade_counts, 0), do: {nil, 0.0}
  defp calculate_concentration(trade_counts, total) do
    case Enum.max_by(trade_counts, fn {_, count} -> count end, fn -> {nil, 0} end) do
      {nil, 0} -> {nil, 0.0}
      {cat, count} -> {cat, count / total}
    end
  end

  defp calculate_health_score(categories, concentration, categories_with_data) do
    # Health score from 0-100
    # Factors:
    # - Category diversity (more categories = better): 40 points
    # - Low concentration (spread across categories): 30 points
    # - Freshness (no stale categories): 30 points

    diversity_score = min(categories_with_data / length(@all_categories), 1.0) * 40

    concentration_score = (1 - min(concentration, 1.0)) * 30

    stale_count = Enum.count(categories, & &1.is_stale)
    freshness_score = max(0, 1 - (stale_count / length(@all_categories))) * 30

    round(diversity_score + concentration_score + freshness_score)
  end

  defp build_alerts(coverage) do
    []
    |> add_critical_alerts(coverage)
    |> add_concentration_alerts(coverage)
    |> add_missing_alerts(coverage)
    |> add_stale_alerts(coverage)
    |> add_diversity_alerts(coverage)
  end

  defp add_critical_alerts(alerts, coverage) do
    Enum.reduce(coverage.critical_categories, alerts, fn cat, acc ->
      hours = div(cat.staleness_seconds, 3600)
      [%{
        severity: :critical,
        category: cat.category,
        type: :critical_staleness,
        message: "#{cat.category}: CRITICAL - No trades in #{hours}h (>24h threshold)"
      } | acc]
    end)
  end

  defp add_concentration_alerts(alerts, coverage) do
    if coverage.is_concentrated do
      pct = Float.round(coverage.concentration * 100, 1)
      [%{
        severity: :warning,
        category: coverage.top_category,
        type: :concentration,
        message: "High concentration: #{pct}% of trades from #{coverage.top_category} (threshold: #{@concentration_threshold * 100}%)"
      } | alerts]
    else
      alerts
    end
  end

  defp add_missing_alerts(alerts, coverage) do
    Enum.reduce(coverage.missing_categories, alerts, fn cat, acc ->
      [%{
        severity: :warning,
        category: cat.category,
        type: :missing,
        message: "#{cat.category}: No trades captured (#{cat.total_markets} markets available)"
      } | acc]
    end)
  end

  defp add_stale_alerts(alerts, coverage) do
    # Only add stale alerts for non-critical categories (critical already added)
    stale_non_critical = Enum.filter(coverage.stale_categories, fn cat ->
      !cat.is_critical
    end)

    Enum.reduce(stale_non_critical, alerts, fn cat, acc ->
      hours = div(cat.staleness_seconds, 3600)
      [%{
        severity: :warning,
        category: cat.category,
        type: :stale,
        message: "#{cat.category}: Stale data (#{hours}h since last trade)"
      } | acc]
    end)
  end

  defp add_diversity_alerts(alerts, coverage) do
    if coverage.categories_with_data < @min_category_coverage do
      [%{
        severity: :warning,
        category: nil,
        type: :low_diversity,
        message: "Low diversity: Only #{coverage.categories_with_data}/#{length(@all_categories)} categories have trades (minimum: #{@min_category_coverage})"
      } | alerts]
    else
      alerts
    end
  end
end
