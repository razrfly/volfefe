defmodule Mix.Tasks.Polymarket.ScanActive do
  @moduledoc """
  Scan active (unresolved) markets for suspicious trading activity.

  Identifies markets that are still open but show signs of potential
  insider trading, ranked by a composite "watchability" score.

  ## Watchability Score

  Markets are ranked by combining:
  - **Anomaly Signal**: Maximum ensemble score of trades in the market
  - **Volume Signal**: Total suspicious trade volume
  - **Urgency Signal**: How soon the market resolves (closer = more urgent)

  ```
  watchability = (max_ensemble * 0.5) + (volume_factor * 0.3) + (urgency * 0.2)
  ```

  ## Usage

      # Scan all active markets
      mix polymarket.scan_active

      # Limit results
      mix polymarket.scan_active --limit 20

      # Filter by minimum anomaly score
      mix polymarket.scan_active --min-score 0.6

      # Filter by category
      mix polymarket.scan_active --category crypto
      mix polymarket.scan_active --category politics

      # Show only markets ending soon (within N days)
      mix polymarket.scan_active --ending-within 7

      # Export to CSV
      mix polymarket.scan_active --export csv

  ## Options

      --limit           Maximum markets to show (default: 25)
      --min-score       Minimum max ensemble score (default: 0.5)
      --category        Filter by category (crypto, politics, sports, etc.)
      --ending-within   Only markets ending within N days
      --export          Export format: csv
      --verbose         Show additional details per market

  ## Output

      ACTIVE MARKETS TO WATCH (15 found)
      ═══════════════════════════════════════════════════════════════

      #1 [CRITICAL] Will Bitcoin hit $150K by March?
         Watchability: 0.89 | Max Anomaly: 0.94 | Suspicious Trades: 12
         Volume: $45,230 suspicious | Ends: 3 days
         Top Wallet: 0x4ffe...09f71 (4 trades, ensemble avg: 0.87)

      #2 [HIGH] Will Ethereum dip to $2,800?
         ...
  """

  use Mix.Task
  require Logger
  import Ecto.Query

  alias VolfefeMachine.Repo
  alias VolfefeMachine.Polymarket.{Market, Trade, TradeScore}

  @shortdoc "Scan active markets for suspicious activity"

  @default_limit 25
  @default_min_score 0.5

  @impl Mix.Task
  def run(args) do
    Mix.Task.run("app.start")

    {opts, _, _} = OptionParser.parse(args,
      switches: [
        limit: :integer,
        min_score: :float,
        category: :string,
        ending_within: :integer,
        export: :string,
        verbose: :boolean
      ],
      aliases: [l: :limit, m: :min_score, c: :category, e: :export, v: :verbose]
    )

    print_header()

    limit = opts[:limit] || @default_limit
    min_score = opts[:min_score] || @default_min_score
    category = opts[:category]
    ending_within = opts[:ending_within]
    export = opts[:export]
    verbose = opts[:verbose] || false

    # Find active markets with suspicious trades
    markets = find_suspicious_active_markets(min_score, category, ending_within)

    if length(markets) == 0 do
      Mix.shell().info("No active markets found with suspicious activity (min_score: #{min_score})")
    else
      # Rank by watchability score
      ranked = markets
      |> Enum.map(&calculate_watchability/1)
      |> Enum.sort_by(& &1.watchability, :desc)
      |> Enum.take(limit)

      case export do
        "csv" -> export_csv(ranked)
        _ -> display_results(ranked, verbose)
      end
    end

    print_footer()
  end

  # ============================================
  # Data Queries
  # ============================================

  defp find_suspicious_active_markets(min_score, category, ending_within) do
    min_score_decimal = Decimal.from_float(min_score)
    now = DateTime.utc_now()

    # Base query: unresolved markets with scored trades
    base_query = from(m in Market,
      join: t in Trade, on: t.market_id == m.id,
      join: ts in TradeScore, on: ts.trade_id == t.id,
      where: is_nil(m.resolved_outcome),  # Not resolved
      where: m.is_active == true,          # Still active
      where: ts.ensemble_score >= ^min_score_decimal,  # Has suspicious trades
      group_by: m.id,
      select: %{
        market: m,
        max_ensemble: max(ts.ensemble_score),
        avg_ensemble: avg(ts.ensemble_score),
        suspicious_trade_count: count(ts.id),
        suspicious_volume: sum(t.usdc_size),
        unique_wallets: count(t.wallet_address, :distinct)
      }
    )

    # Apply category filter
    base_query = if category do
      category_atom = String.to_existing_atom(category)
      from([m, t, ts] in base_query, where: m.category == ^category_atom)
    else
      base_query
    end

    # Apply ending_within filter
    base_query = if ending_within do
      cutoff = DateTime.add(now, ending_within * 24 * 60 * 60, :second)
      from([m, t, ts] in base_query,
        where: not is_nil(m.end_date) and m.end_date <= ^cutoff
      )
    else
      base_query
    end

    Repo.all(base_query)
  end

  # ============================================
  # Watchability Calculation
  # ============================================

  defp calculate_watchability(market_data) do
    now = DateTime.utc_now()

    # Extract values
    max_ensemble = decimal_to_float(market_data.max_ensemble)
    suspicious_volume = decimal_to_float(market_data.suspicious_volume)
    end_date = market_data.market.end_date

    # Anomaly signal (0-1): direct from max ensemble score
    anomaly_signal = max_ensemble

    # Volume signal (0-1): log-normalized suspicious volume
    # $1K = 0.3, $10K = 0.5, $100K = 0.7, $1M = 0.9
    volume_signal = cond do
      suspicious_volume <= 0 -> 0.0
      suspicious_volume < 1000 -> 0.2
      suspicious_volume < 10_000 -> 0.3 + (0.2 * :math.log10(suspicious_volume / 1000))
      suspicious_volume < 100_000 -> 0.5 + (0.2 * :math.log10(suspicious_volume / 10_000))
      suspicious_volume < 1_000_000 -> 0.7 + (0.2 * :math.log10(suspicious_volume / 100_000))
      true -> 0.95
    end

    # Urgency signal (0-1): based on days until resolution
    urgency_signal = if end_date do
      days_until = DateTime.diff(end_date, now, :second) / 86400
      cond do
        days_until <= 0 -> 1.0      # Already ended/ending today
        days_until <= 1 -> 0.95     # Within 24 hours
        days_until <= 3 -> 0.85     # Within 3 days
        days_until <= 7 -> 0.7      # Within a week
        days_until <= 14 -> 0.5     # Within 2 weeks
        days_until <= 30 -> 0.3     # Within a month
        true -> 0.1                  # More than a month
      end
    else
      0.3  # Unknown end date
    end

    # Composite watchability score
    watchability = (anomaly_signal * 0.5) + (volume_signal * 0.3) + (urgency_signal * 0.2)

    # Determine tier
    tier = cond do
      watchability >= 0.8 -> :critical
      watchability >= 0.6 -> :high
      watchability >= 0.4 -> :medium
      true -> :low
    end

    # Get top wallet for this market
    top_wallet = get_top_wallet(market_data.market.id)

    # Days until end
    days_until_end = if end_date do
      days = DateTime.diff(end_date, now, :second) / 86400
      if days < 0, do: 0, else: Float.round(days, 1)
    else
      nil
    end

    %{
      market: market_data.market,
      watchability: Float.round(watchability, 4),
      tier: tier,
      max_ensemble: Float.round(max_ensemble, 4),
      avg_ensemble: Float.round(decimal_to_float(market_data.avg_ensemble), 4),
      suspicious_trade_count: market_data.suspicious_trade_count,
      suspicious_volume: Float.round(suspicious_volume, 2),
      unique_wallets: market_data.unique_wallets,
      days_until_end: days_until_end,
      anomaly_signal: Float.round(anomaly_signal, 3),
      volume_signal: Float.round(volume_signal, 3),
      urgency_signal: Float.round(urgency_signal, 3),
      top_wallet: top_wallet
    }
  end

  defp get_top_wallet(market_id) do
    query = from(t in Trade,
      join: ts in TradeScore, on: ts.trade_id == t.id,
      where: t.market_id == ^market_id,
      where: not is_nil(ts.ensemble_score),
      group_by: t.wallet_address,
      order_by: [desc: max(ts.ensemble_score)],
      limit: 1,
      select: %{
        wallet_address: t.wallet_address,
        trade_count: count(t.id),
        max_ensemble: max(ts.ensemble_score),
        avg_ensemble: avg(ts.ensemble_score)
      }
    )

    Repo.one(query)
  end

  # ============================================
  # Display Functions
  # ============================================

  defp display_results(ranked, verbose) do
    total = length(ranked)
    Mix.shell().info("ACTIVE MARKETS TO WATCH (#{total} found)")
    Mix.shell().info(String.duplicate("═", 65))
    Mix.shell().info("")

    Enum.with_index(ranked, 1)
    |> Enum.each(fn {data, idx} ->
      display_market(data, idx, verbose)
    end)

    # Summary stats
    Mix.shell().info("")
    Mix.shell().info(String.duplicate("─", 65))
    display_summary(ranked)
  end

  defp display_market(data, idx, verbose) do
    tier_badge = tier_badge(data.tier)
    question = truncate(data.market.question || "Unknown", 50)

    Mix.shell().info("##{idx} #{tier_badge} #{question}")
    Mix.shell().info("   Watchability: #{format_score(data.watchability)} | Max Anomaly: #{format_score(data.max_ensemble)} | Suspicious Trades: #{data.suspicious_trade_count}")
    Mix.shell().info("   Volume: #{format_money(data.suspicious_volume)} suspicious | Ends: #{format_days(data.days_until_end)}")

    if data.top_wallet do
      wallet_short = String.slice(data.top_wallet.wallet_address || "", 0..5) <> "..." <> String.slice(data.top_wallet.wallet_address || "", -5..-1)
      Mix.shell().info("   Top Wallet: #{wallet_short} (#{data.top_wallet.trade_count} trades, avg: #{format_score(decimal_to_float(data.top_wallet.avg_ensemble))})")
    end

    if verbose do
      Mix.shell().info("   Signals: anomaly=#{data.anomaly_signal}, volume=#{data.volume_signal}, urgency=#{data.urgency_signal}")
      Mix.shell().info("   Category: #{data.market.category} | Unique Wallets: #{data.unique_wallets}")
      Mix.shell().info("   Condition ID: #{data.market.condition_id}")
    end

    Mix.shell().info("")
  end

  defp display_summary(ranked) do
    critical = Enum.count(ranked, &(&1.tier == :critical))
    high = Enum.count(ranked, &(&1.tier == :high))
    medium = Enum.count(ranked, &(&1.tier == :medium))
    low = Enum.count(ranked, &(&1.tier == :low))

    total_volume = Enum.reduce(ranked, 0, &(&1.suspicious_volume + &2))
    total_trades = Enum.reduce(ranked, 0, &(&1.suspicious_trade_count + &2))

    Mix.shell().info("Summary:")
    Mix.shell().info("  Critical: #{critical} | High: #{high} | Medium: #{medium} | Low: #{low}")
    Mix.shell().info("  Total Suspicious Volume: #{format_money(total_volume)}")
    Mix.shell().info("  Total Suspicious Trades: #{total_trades}")
  end

  # ============================================
  # Export Functions
  # ============================================

  defp export_csv(ranked) do
    headers = "rank,tier,watchability,question,category,condition_id,max_ensemble,avg_ensemble,suspicious_trades,suspicious_volume,unique_wallets,days_until_end,top_wallet"
    Mix.shell().info(headers)

    Enum.with_index(ranked, 1)
    |> Enum.each(fn {data, idx} ->
      row = [
        idx,
        data.tier,
        data.watchability,
        "\"#{escape_csv(data.market.question)}\"",
        data.market.category,
        data.market.condition_id,
        data.max_ensemble,
        data.avg_ensemble,
        data.suspicious_trade_count,
        data.suspicious_volume,
        data.unique_wallets,
        data.days_until_end || "unknown",
        data.top_wallet && data.top_wallet.wallet_address || ""
      ] |> Enum.join(",")

      Mix.shell().info(row)
    end)
  end

  # ============================================
  # Formatting Helpers
  # ============================================

  defp tier_badge(:critical), do: "[CRITICAL]"
  defp tier_badge(:high), do: "[HIGH]"
  defp tier_badge(:medium), do: "[MEDIUM]"
  defp tier_badge(:low), do: "[LOW]"

  defp format_score(score) when is_float(score), do: Float.round(score, 2) |> to_string()
  defp format_score(score), do: "#{score}"

  defp format_money(amount) when is_float(amount) do
    cond do
      amount >= 1_000_000 -> "$#{Float.round(amount / 1_000_000, 1)}M"
      amount >= 1_000 -> "$#{Float.round(amount / 1_000, 1)}K"
      true -> "$#{Float.round(amount, 0)}"
    end
  end
  defp format_money(_), do: "$0"

  defp format_days(nil), do: "unknown"
  defp format_days(days) when days <= 0, do: "ending now"
  defp format_days(days) when days < 1, do: "< 1 day"
  defp format_days(days) when days == 1.0, do: "1 day"
  defp format_days(days), do: "#{days} days"

  defp truncate(nil, _), do: ""
  defp truncate(str, max) when byte_size(str) > max do
    String.slice(str, 0, max - 3) <> "..."
  end
  defp truncate(str, _), do: str

  defp escape_csv(nil), do: ""
  defp escape_csv(str), do: String.replace(str, "\"", "\"\"")

  defp decimal_to_float(nil), do: 0.0
  defp decimal_to_float(%Decimal{} = d), do: Decimal.to_float(d)
  defp decimal_to_float(n) when is_float(n), do: n
  defp decimal_to_float(n) when is_integer(n), do: n * 1.0

  defp print_header do
    Mix.shell().info("")
    Mix.shell().info("╔══════════════════════════════════════════════════════════════╗")
    Mix.shell().info("║ POLYMARKET ACTIVE MARKET SCANNER                             ║")
    Mix.shell().info("╚══════════════════════════════════════════════════════════════╝")
    Mix.shell().info("")
  end

  defp print_footer do
    Mix.shell().info("")
    Mix.shell().info("Next steps:")
    Mix.shell().info("  • Investigate specific market: mix polymarket.investigate_market <condition_id>")
    Mix.shell().info("  • View wallet details: mix polymarket.investigate_wallet <address>")
    Mix.shell().info("")
  end
end
