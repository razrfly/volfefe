defmodule VolfefeMachine.Polymarket.CrossMarketScanner do
  @moduledoc """
  Phase 3: Cross-Market Wallet Scanning

  Scans wallets across multiple markets to identify:
  1. Repeat offenders - confirmed insiders trading on other markets
  2. Similar patterns - wallets behaving like known insiders
  3. Wallet networks - clusters of wallets trading together suspiciously

  ## Purpose

  Use confirmed insider behavior patterns to find unknown insiders:
  - If wallet X was insider on Market A, check their trades on Markets B, C, D
  - Find wallets that exhibit same patterns across multiple markets
  - Build larger training set for Phase 4 proactive detection

  ## Usage

      # Scan confirmed insider wallets across all markets
      {:ok, results} = CrossMarketScanner.scan_insider_wallets()

      # Find wallets similar to insiders
      {:ok, similar} = CrossMarketScanner.find_similar_wallets(opts)

      # Analyze wallet network connections
      {:ok, network} = CrossMarketScanner.analyze_wallet_network(wallet_address)
  """

  require Logger
  import Ecto.Query
  alias VolfefeMachine.Repo
  alias VolfefeMachine.Polymarket.{Trade, Market, ConfirmedInsider, InvestigationCandidate}

  # Scoring weights for cross-market suspicion
  @timing_weight 0.35
  @volume_weight 0.25
  @win_rate_weight 0.20
  @market_count_weight 0.10
  @pattern_weight 0.10

  # Thresholds
  @min_suspicious_score 0.35  # Lowered to catch high win-rate wallets without timing data
  @high_priority_score 0.6
  @critical_priority_score 0.8

  # ============================================================================
  # Core Scanning Functions
  # ============================================================================

  @doc """
  Scans all confirmed insider wallets across all markets they've traded on.

  Returns suspicious activity on markets OTHER than where they were confirmed.

  ## Options

  - `:min_score` - Minimum suspicion score to include (default: 0.5)
  - `:include_confirmed_markets` - Include markets where already confirmed (default: false)

  ## Returns

  ```
  {:ok, %{
    wallets_scanned: 5,
    markets_analyzed: 12,
    suspicious_trades: [...],
    new_candidates: 3
  }}
  ```
  """
  def scan_insider_wallets(opts \\ []) do
    min_score = Keyword.get(opts, :min_score, @min_suspicious_score)
    include_confirmed = Keyword.get(opts, :include_confirmed_markets, false)

    # Get all confirmed insider wallets
    insiders = Repo.all(
      from c in ConfirmedInsider,
      select: %{
        wallet_address: c.wallet_address,
        condition_id: c.condition_id,
        confidence_level: c.confidence_level
      }
    )

    if Enum.empty?(insiders) do
      {:error, "No confirmed insiders to scan"}
    else
      results = Enum.map(insiders, fn insider ->
        scan_wallet_across_markets(insider, include_confirmed, min_score)
      end)

      # Aggregate results
      all_suspicious = results
      |> Enum.flat_map(& &1.suspicious_trades)
      |> Enum.sort_by(& &1.suspicion_score, :desc)

      {:ok, %{
        wallets_scanned: length(insiders),
        markets_analyzed: results |> Enum.map(& &1.markets_checked) |> Enum.sum(),
        suspicious_trades: all_suspicious,
        summary: build_scan_summary(results)
      }}
    end
  end

  @doc """
  Finds wallets that exhibit similar trading patterns to confirmed insiders.

  Looks for:
  - Similar timing patterns (trades close to market resolution)
  - Similar volume patterns (large single trades)
  - High win rates across multiple markets
  - Trading on overlapping markets with insiders

  ## Options

  - `:min_markets` - Minimum markets traded (default: 2)
  - `:min_win_rate` - Minimum win rate to consider (default: 0.7)
  - `:limit` - Maximum results (default: 50)
  """
  def find_similar_wallets(opts \\ []) do
    min_markets = Keyword.get(opts, :min_markets, 2)
    min_win_rate = Keyword.get(opts, :min_win_rate, 0.7)
    limit = Keyword.get(opts, :limit, 50)

    # Get insider wallet addresses to exclude
    insider_wallets = Repo.all(
      from c in ConfirmedInsider, select: c.wallet_address
    ) |> MapSet.new()

    # Get candidate wallets to exclude
    candidate_wallets = Repo.all(
      from c in InvestigationCandidate, select: c.wallet_address
    ) |> MapSet.new()

    excluded_wallets = MapSet.union(insider_wallets, candidate_wallets)

    # Find wallets with suspicious cross-market patterns
    wallet_stats = calculate_wallet_stats(excluded_wallets, min_markets)

    # Score and filter
    scored_wallets = wallet_stats
    |> Enum.map(&score_wallet_suspicion/1)
    |> Enum.filter(fn w -> w.suspicion_score >= @min_suspicious_score end)
    |> Enum.filter(fn w ->
      w.win_rate >= min_win_rate or w.suspicion_score >= @high_priority_score
    end)
    |> Enum.sort_by(& &1.suspicion_score, :desc)
    |> Enum.take(limit)

    {:ok, %{
      wallets_found: length(scored_wallets),
      wallets: scored_wallets,
      excluded_count: MapSet.size(excluded_wallets)
    }}
  end

  @doc """
  Analyzes a specific wallet's trading network.

  Finds:
  - All markets the wallet has traded on
  - Other wallets that trade on the same markets with similar timing
  - Potential connected wallets (same funding source, coordinated trades)

  ## Returns

  ```
  {:ok, %{
    wallet: "0x...",
    markets_traded: 5,
    market_details: [...],
    connected_wallets: [...],
    network_risk_score: 0.75
  }}
  ```
  """
  def analyze_wallet_network(wallet_address) do
    # Get all trades for this wallet
    trades = Repo.all(
      from t in Trade,
      where: t.wallet_address == ^wallet_address,
      select: %{
        condition_id: t.condition_id,
        trade_timestamp: t.trade_timestamp,
        size: t.size,
        side: t.side,
        outcome: t.outcome,
        was_correct: t.was_correct
      }
    )

    if Enum.empty?(trades) do
      {:error, "No trades found for wallet"}
    else
      # Group by market
      by_market = Enum.group_by(trades, & &1.condition_id)

      # Analyze each market
      market_details = Enum.map(by_market, fn {condition_id, market_trades} ->
        analyze_market_activity(condition_id, market_trades, wallet_address)
      end)

      # Find connected wallets (trade same markets within similar timeframes)
      connected = find_connected_wallets(wallet_address, by_market)

      # Calculate network risk score
      network_score = calculate_network_risk(market_details, connected)

      {:ok, %{
        wallet: wallet_address,
        markets_traded: map_size(by_market),
        total_trades: length(trades),
        market_details: market_details,
        connected_wallets: connected,
        network_risk_score: network_score
      }}
    end
  end

  @doc """
  Promotes cross-market findings to investigation candidates.

  Takes results from scan_insider_wallets or find_similar_wallets and
  creates InvestigationCandidate records.

  ## Options

  - `:min_score` - Minimum score to promote (default: 0.6)
  - `:limit` - Maximum candidates to create (default: 20)
  - `:batch_prefix` - Prefix for batch ID (default: "crossmarket")
  """
  def promote_to_candidates(suspicious_items, opts \\ []) do
    min_score = Keyword.get(opts, :min_score, 0.6)
    limit = Keyword.get(opts, :limit, 20)
    batch_prefix = Keyword.get(opts, :batch_prefix, "crossmarket")

    eligible = suspicious_items
    |> Enum.filter(fn item -> item.suspicion_score >= min_score end)
    |> Enum.take(limit)

    if Enum.empty?(eligible) do
      {:ok, %{candidates_created: 0, batch_id: nil}}
    else
      batch_id = "#{batch_prefix}-#{DateTime.utc_now() |> DateTime.to_unix()}"

      results = Enum.with_index(eligible, 1)
      |> Enum.map(fn {item, rank} ->
        create_candidate_from_scan(item, rank, batch_id)
      end)

      successful = Enum.count(results, &match?({:ok, _}, &1))

      {:ok, %{
        candidates_created: successful,
        batch_id: batch_id,
        failed: length(results) - successful
      }}
    end
  end

  # ============================================================================
  # Private: Wallet Scanning
  # ============================================================================

  defp scan_wallet_across_markets(insider, include_confirmed, min_score) do
    wallet = insider.wallet_address
    confirmed_market = insider.condition_id

    # Get all trades for this wallet
    trades = Repo.all(
      from t in Trade,
      where: t.wallet_address == ^wallet,
      preload: [:market]
    )

    # Group by market and filter out confirmed market if needed
    by_market = trades
    |> Enum.group_by(& &1.condition_id)
    |> Enum.reject(fn {cid, _} ->
      not include_confirmed and cid == confirmed_market
    end)

    # Analyze each market
    suspicious = Enum.flat_map(by_market, fn {condition_id, market_trades} ->
      analyze_trades_for_suspicion(wallet, condition_id, market_trades, min_score)
    end)

    %{
      wallet: wallet,
      confirmed_market: confirmed_market,
      confidence: insider.confidence_level,
      markets_checked: length(by_market),
      suspicious_trades: suspicious
    }
  end

  defp analyze_trades_for_suspicion(wallet, condition_id, trades, min_score) do
    # Get market info
    market = Repo.one(from m in Market, where: m.condition_id == ^condition_id)

    resolution_date = if market do
      market.resolution_date || market.end_date
    end

    # Calculate aggregates
    total_volume = trades
    |> Enum.map(& &1.size)
    |> Enum.reduce(Decimal.new(0), fn size, acc ->
      Decimal.add(acc, size || Decimal.new(0))
    end)

    # Find earliest trade timing relative to resolution
    timing_data = if resolution_date do
      trades
      |> Enum.map(fn t ->
        hours = calculate_hours_before(t.trade_timestamp, resolution_date)
        %{trade: t, hours_before: hours}
      end)
      |> Enum.filter(& &1.hours_before)
      |> Enum.min_by(& &1.hours_before, fn -> nil end)
    end

    min_hours = if timing_data, do: timing_data.hours_before

    # Check if trades were correct
    correct_trades = Enum.count(trades, & &1.was_correct == true)
    total_resolved = Enum.count(trades, & &1.was_correct != nil)
    win_rate = if total_resolved > 0, do: correct_trades / total_resolved, else: nil

    # Calculate suspicion score
    score = calculate_trade_suspicion_score(%{
      volume: total_volume,
      hours_before: min_hours,
      trade_count: length(trades),
      win_rate: win_rate
    })

    if score >= min_score do
      [%{
        wallet_address: wallet,
        condition_id: condition_id,
        market_question: market && market.question,
        total_volume: total_volume,
        trade_count: length(trades),
        hours_before_resolution: min_hours,
        win_rate: win_rate,
        suspicion_score: score,
        priority: score_to_priority(score),
        source: "cross_market_insider_scan"
      }]
    else
      []
    end
  end

  defp calculate_trade_suspicion_score(data) do
    volume = Decimal.to_float(data.volume || Decimal.new(0))
    hours = data.hours_before
    win_rate = data.win_rate || 0

    # Volume score (0-1)
    volume_score = min(1.0, volume / 50_000)

    # Timing score (0-1) - closer to event = higher score
    timing_score = cond do
      hours == nil -> 0.3
      hours <= 24 -> 1.0
      hours <= 72 -> 0.8
      hours <= 168 -> 0.6
      hours <= 336 -> 0.4
      true -> 0.2
    end

    # Win rate score (0-1)
    win_score = if win_rate, do: win_rate, else: 0.5

    # Combine scores
    volume_score * @volume_weight +
    timing_score * @timing_weight +
    win_score * @win_rate_weight +
    0.5 * @market_count_weight +
    0.5 * @pattern_weight
  end

  # ============================================================================
  # Private: Similar Wallet Detection
  # ============================================================================

  defp calculate_wallet_stats(excluded_wallets, min_markets) do
    # Query wallet statistics across markets
    query = from t in Trade,
      group_by: t.wallet_address,
      having: count(t.condition_id, :distinct) >= ^min_markets,
      select: %{
        wallet_address: t.wallet_address,
        market_count: count(t.condition_id, :distinct),
        total_trades: count(t.id),
        total_volume: sum(t.size),
        wins: fragment("COUNT(CASE WHEN ? = true THEN 1 END)", t.was_correct),
        total_resolved: fragment("COUNT(CASE WHEN ? IS NOT NULL THEN 1 END)", t.was_correct),
        min_hours_before: min(t.hours_before_resolution),
        avg_trade_size: avg(t.size)
      }

    Repo.all(query)
    |> Enum.reject(fn w -> MapSet.member?(excluded_wallets, w.wallet_address) end)
    |> Enum.map(fn w ->
      win_rate = if w.total_resolved > 0, do: w.wins / w.total_resolved, else: nil
      Map.put(w, :win_rate, win_rate)
    end)
  end

  defp score_wallet_suspicion(wallet_stats) do
    volume = Decimal.to_float(wallet_stats.total_volume || Decimal.new(0))
    hours = wallet_stats.min_hours_before
    win_rate = wallet_stats.win_rate || 0
    market_count = wallet_stats.market_count

    # Volume score
    volume_score = min(1.0, volume / 100_000)

    # Timing score
    timing_score = cond do
      hours == nil -> 0.3
      hours <= 24 -> 1.0
      hours <= 72 -> 0.8
      hours <= 168 -> 0.6
      true -> 0.3
    end

    # Win rate score (high win rate across multiple markets is very suspicious)
    win_score = win_rate

    # Market count score (more markets = more concerning if pattern holds)
    market_score = min(1.0, market_count / 10)

    # Pattern consistency score
    pattern_score = if win_rate > 0.8 and market_count >= 3, do: 1.0, else: 0.5

    suspicion_score =
      volume_score * @volume_weight +
      timing_score * @timing_weight +
      win_score * @win_rate_weight +
      market_score * @market_count_weight +
      pattern_score * @pattern_weight

    wallet_stats
    |> Map.put(:suspicion_score, Float.round(suspicion_score, 4))
    |> Map.put(:priority, score_to_priority(suspicion_score))
    |> Map.put(:source, "similar_wallet_detection")
  end

  # ============================================================================
  # Private: Network Analysis
  # ============================================================================

  defp analyze_market_activity(condition_id, trades, _wallet_address) do
    market = Repo.one(from m in Market, where: m.condition_id == ^condition_id)

    total_volume = trades
    |> Enum.map(& &1.size)
    |> Enum.reduce(Decimal.new(0), fn size, acc ->
      Decimal.add(acc, size || Decimal.new(0))
    end)

    wins = Enum.count(trades, & &1.was_correct == true)
    resolved = Enum.count(trades, & &1.was_correct != nil)

    %{
      condition_id: condition_id,
      market_question: market && market.question,
      trade_count: length(trades),
      total_volume: total_volume,
      wins: wins,
      resolved: resolved,
      win_rate: if(resolved > 0, do: wins / resolved, else: nil),
      first_trade: trades |> Enum.map(& &1.trade_timestamp) |> Enum.min(DateTime, fn -> nil end),
      last_trade: trades |> Enum.map(& &1.trade_timestamp) |> Enum.max(DateTime, fn -> nil end)
    }
  end

  defp find_connected_wallets(wallet_address, markets_traded) do
    condition_ids = Map.keys(markets_traded)
    num_markets = length(condition_ids)

    if Enum.empty?(condition_ids) do
      []
    else
      # Find wallets that trade on the same markets within 24 hours of target wallet
      query = from t in Trade,
        where: t.condition_id in ^condition_ids,
        where: t.wallet_address != ^wallet_address,
        group_by: t.wallet_address,
        having: count(t.condition_id, :distinct) >= 2,
        select: %{
          wallet_address: t.wallet_address,
          shared_markets: count(t.condition_id, :distinct),
          total_volume: sum(t.size)
        },
        order_by: [desc: count(t.condition_id, :distinct)],
        limit: 20

      Repo.all(query)
      |> Enum.map(fn connected ->
        overlap_score = connected.shared_markets / num_markets
        Map.put(connected, :overlap_score, Float.round(overlap_score, 3))
      end)
    end
  end

  defp calculate_network_risk(market_details, connected_wallets) do
    # Base risk from market performance
    market_risk = market_details
    |> Enum.filter(& &1.win_rate)
    |> Enum.map(& &1.win_rate)
    |> case do
      [] -> 0.5
      rates -> Enum.sum(rates) / length(rates)
    end

    # Risk from connected wallets
    connection_risk = case length(connected_wallets) do
      0 -> 0.2
      n when n <= 3 -> 0.4
      n when n <= 10 -> 0.6
      _ -> 0.8
    end

    # Combine
    Float.round(market_risk * 0.7 + connection_risk * 0.3, 4)
  end

  # ============================================================================
  # Private: Candidate Creation
  # ============================================================================

  defp create_candidate_from_scan(item, rank, batch_id) do
    # Convert Decimal/numeric timing to float for JSON storage
    timing = case item[:hours_before_resolution] || item[:min_hours_before] do
      %Decimal{} = d -> Decimal.to_float(d)
      n when is_number(n) -> n
      _ -> nil
    end

    attrs = %{
      wallet_address: item.wallet_address,
      condition_id: item[:condition_id],
      discovery_rank: rank,
      anomaly_score: Decimal.from_float(item.suspicion_score),
      insider_probability: Decimal.from_float(item.suspicion_score),
      market_question: item[:market_question],
      trade_size: item[:total_volume],
      estimated_profit: item[:total_volume],
      hours_before_resolution: timing,
      anomaly_breakdown: %{
        "source" => item.source,
        "market_count" => item[:market_count],
        "win_rate" => item[:win_rate],
        "timing" => timing
      },
      matched_patterns: %{
        "detection_method" => "cross_market_scan",
        "original_source" => item.source
      },
      status: "undiscovered",
      priority: item.priority,
      batch_id: batch_id,
      discovered_at: DateTime.utc_now() |> DateTime.truncate(:second)
    }

    %InvestigationCandidate{}
    |> InvestigationCandidate.changeset(attrs)
    |> Repo.insert()
  end

  # ============================================================================
  # Private: Utilities
  # ============================================================================

  defp calculate_hours_before(trade_time, resolution_time) do
    case {trade_time, resolution_time} do
      {%DateTime{} = t, %DateTime{} = r} ->
        seconds = DateTime.diff(r, t, :second)
        if seconds > 0, do: Float.round(seconds / 3600, 2)
      _ ->
        nil
    end
  end

  defp score_to_priority(score) when score >= @critical_priority_score, do: "critical"
  defp score_to_priority(score) when score >= @high_priority_score, do: "high"
  defp score_to_priority(score) when score >= @min_suspicious_score, do: "medium"
  defp score_to_priority(_), do: "low"

  defp build_scan_summary(results) do
    total_suspicious = results |> Enum.flat_map(& &1.suspicious_trades) |> length()

    by_priority = results
    |> Enum.flat_map(& &1.suspicious_trades)
    |> Enum.group_by(& &1.priority)
    |> Enum.map(fn {k, v} -> {k, length(v)} end)
    |> Map.new()

    %{
      total_suspicious: total_suspicious,
      by_priority: by_priority,
      wallets_with_cross_market: Enum.count(results, fn r ->
        length(r.suspicious_trades) > 0
      end)
    }
  end
end
