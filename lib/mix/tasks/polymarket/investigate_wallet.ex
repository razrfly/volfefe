defmodule Mix.Tasks.Polymarket.InvestigateWallet do
  @moduledoc """
  Deep investigation of a wallet address.

  Provides comprehensive analysis including trade history, win rate,
  score distribution, suspicious markets, and related wallets.

  ## Usage

      # Investigate a wallet by address
      mix polymarket.investigate_wallet 0x511374966ad5f98abf5a200b2d5ea94b46b9f0ba

      # Show verbose output with all trades
      mix polymarket.investigate_wallet 0x511374966ad5f98abf5a200b2d5ea94b46b9f0ba --verbose

      # Limit trades shown
      mix polymarket.investigate_wallet 0x511374966ad5f98abf5a200b2d5ea94b46b9f0ba --limit 10

  ## Options

      --verbose   Show all trades (default: top 20)
      --limit     Limit trades shown (default: 20)
      --json      Output as JSON

  ## Examples

      $ mix polymarket.investigate_wallet 0x511374966ad5f98abf5a200b2d5ea94b46b9f0ba

      WALLET INVESTIGATION
      ═══════════════════════════════════════════════════════════════

      ADDRESS: 0x5113...f0ba

      PROFILE
      ├─ Total Trades:    19
      ├─ Win Rate:        100.0% (19/19)
      ├─ Total Volume:    $45,230.00
      ├─ Unique Markets:  7
      ├─ Account Age:     45 days
      └─ First Trade:     2024-01-15

      SCORE DISTRIBUTION
      ├─ Critical (>0.9): 5
      ├─ High (>0.7):     10
      ├─ Medium (>0.5):   4
      ├─ Low (>0.3):      0
      └─ Normal (≤0.3):   0

      RISK ASSESSMENT
      └─ 🚨 CRITICAL: Perfect win rate with high scores

      MARKETS TRADED
      ├─ Will X happen? (Yes) - 5 trades, 100% wins
      ├─ Will Y happen? (No) - 4 trades, 100% wins
      └─ ...

      TOP SUSPICIOUS TRADES
      ├─ #1: $5,000 on "Will X?" - Score: 0.95 ✅
      ├─ #2: $3,200 on "Will Y?" - Score: 0.91 ✅
      └─ ...
  """

  use Mix.Task
  import Ecto.Query
  alias VolfefeMachine.Repo
  alias VolfefeMachine.Polymarket
  alias VolfefeMachine.Polymarket.{Trade, TradeScore, Market}

  @shortdoc "Deep investigation of a wallet address"

  @impl Mix.Task
  def run(args) do
    Mix.Task.run("app.start")

    {opts, positional, _} = OptionParser.parse(args,
      switches: [
        verbose: :boolean,
        limit: :integer,
        json: :boolean
      ],
      aliases: [v: :verbose, l: :limit, j: :json]
    )

    case positional do
      [] ->
        Mix.shell().error("Error: wallet address is required")
        Mix.shell().info("Usage: mix polymarket.investigate_wallet <address> [options]")

      [address | _] ->
        investigate(address, opts)
    end
  end

  defp investigate(address, opts) do
    # Normalize address
    address = String.downcase(address)
    limit = opts[:limit] || 20

    # Build wallet profile
    profile = Polymarket.build_wallet_profile(address)

    if profile.total_trades == 0 do
      Mix.shell().error("No trades found for wallet: #{address}")
      return_early()
    else
      if opts[:json] do
        output_json(address, profile, opts)
      else
        output_formatted(address, profile, limit, opts[:verbose] || false)
      end
    end
  end

  defp output_formatted(address, profile, limit, verbose) do
    print_header(address)
    print_profile(profile)
    print_score_distribution(address)
    print_risk_assessment(profile)
    print_markets_traded(address)
    print_top_trades(address, limit, verbose)
    print_related_wallets(address)
    print_footer(address)
  end

  defp print_header(address) do
    short_addr = format_wallet(address)
    Mix.shell().info("")
    Mix.shell().info("WALLET INVESTIGATION")
    Mix.shell().info(String.duplicate("═", 65))
    Mix.shell().info("")
    Mix.shell().info("ADDRESS: #{short_addr}")
    Mix.shell().info("Full:    #{address}")
    Mix.shell().info("")
  end

  defp print_profile(profile) do
    Mix.shell().info("PROFILE")
    Mix.shell().info("├─ Total Trades:    #{format_number(profile.total_trades)}")
    Mix.shell().info("├─ Resolved:        #{format_number(profile.resolved_trades)}")

    win_rate_str = if profile.win_rate do
      "#{Float.round(profile.win_rate * 100, 1)}% (#{profile.wins}/#{profile.resolved_trades})"
    else
      "N/A"
    end
    Mix.shell().info("├─ Win Rate:        #{win_rate_str}")

    Mix.shell().info("├─ Unique Markets:  #{profile.unique_markets}")
    Mix.shell().info("├─ Avg Trade Size:  $#{format_number(round(profile.avg_trade_size))}")
    Mix.shell().info("├─ Total Profit:    #{format_profit(profile.total_profit)}")
    Mix.shell().info("├─ Account Age:     #{profile.account_age_days || "?"} days")
    Mix.shell().info("├─ First Trade:     #{format_datetime(profile.first_trade_at)}")
    Mix.shell().info("└─ Last Trade:      #{format_datetime(profile.last_trade_at)}")
    Mix.shell().info("")
  end

  defp print_score_distribution(address) do
    # Query score distribution for this wallet
    dist = Repo.one(from t in Trade,
      join: ts in TradeScore, on: ts.trade_id == t.id,
      where: t.wallet_address == ^address,
      select: %{
        total: count(ts.id),
        critical: count(fragment("CASE WHEN ?::numeric > 0.9 THEN 1 END", ts.anomaly_score)),
        high: count(fragment("CASE WHEN ?::numeric > 0.7 AND ?::numeric <= 0.9 THEN 1 END", ts.anomaly_score, ts.anomaly_score)),
        medium: count(fragment("CASE WHEN ?::numeric > 0.5 AND ?::numeric <= 0.7 THEN 1 END", ts.anomaly_score, ts.anomaly_score)),
        low: count(fragment("CASE WHEN ?::numeric > 0.3 AND ?::numeric <= 0.5 THEN 1 END", ts.anomaly_score, ts.anomaly_score)),
        normal: count(fragment("CASE WHEN ?::numeric <= 0.3 THEN 1 END", ts.anomaly_score)),
        trinity_count: count(fragment("CASE WHEN ? = true THEN 1 END", ts.trinity_pattern))
      }
    )

    if dist && dist.total > 0 do
      Mix.shell().info("SCORE DISTRIBUTION (#{dist.total} scored)")
      Mix.shell().info("├─ 🚨 Critical (>0.9): #{dist.critical}")
      Mix.shell().info("├─ 🔴 High (>0.7):     #{dist.high}")
      Mix.shell().info("├─ 🟠 Medium (>0.5):   #{dist.medium}")
      Mix.shell().info("├─ 🟡 Low (>0.3):      #{dist.low}")
      Mix.shell().info("├─ 🟢 Normal (≤0.3):   #{dist.normal}")
      Mix.shell().info("└─ ⚡ Trinity Pattern: #{dist.trinity_count}")
      Mix.shell().info("")
    else
      Mix.shell().info("SCORE DISTRIBUTION")
      Mix.shell().info("└─ No scored trades")
      Mix.shell().info("")
    end
  end

  defp print_risk_assessment(profile) do
    Mix.shell().info("RISK ASSESSMENT")

    flags = []

    # Perfect/near-perfect win rate
    flags = if profile.win_rate && profile.win_rate >= 0.95 && profile.resolved_trades >= 5 do
      probability = :math.pow(0.5, profile.resolved_trades)
      ["🚨 CRITICAL: #{Float.round(profile.win_rate * 100, 0)}% win rate on #{profile.resolved_trades} trades (p=#{format_scientific(probability)})" | flags]
    else
      flags
    end

    # High win rate
    flags = if profile.win_rate && profile.win_rate >= 0.80 && profile.win_rate < 0.95 && profile.resolved_trades >= 10 do
      ["🔴 HIGH: #{Float.round(profile.win_rate * 100, 0)}% win rate on #{profile.resolved_trades} trades" | flags]
    else
      flags
    end

    # New account with high activity
    flags = if profile.account_age_days && profile.account_age_days < 30 && profile.total_trades >= 10 do
      ["🟠 MEDIUM: New account (#{profile.account_age_days}d) with #{profile.total_trades} trades" | flags]
    else
      flags
    end

    # Large average trade size
    flags = if profile.avg_trade_size >= 5000 do
      ["🟠 MEDIUM: Large average trade size ($#{format_number(round(profile.avg_trade_size))})" | flags]
    else
      flags
    end

    if length(flags) == 0 do
      Mix.shell().info("└─ 🟢 No significant risk indicators")
    else
      flags
      |> Enum.reverse()
      |> Enum.with_index()
      |> Enum.each(fn {flag, idx} ->
        prefix = if idx == length(flags) - 1, do: "└─", else: "├─"
        Mix.shell().info("#{prefix} #{flag}")
      end)
    end

    Mix.shell().info("")
  end

  defp print_markets_traded(address) do
    # Get markets with trade counts and outcomes
    markets = Repo.all(from t in Trade,
      join: m in Market, on: m.id == t.market_id,
      where: t.wallet_address == ^address,
      group_by: [m.id, m.question, t.outcome_index],
      select: %{
        market_id: m.id,
        question: m.question,
        outcome_index: t.outcome_index,
        trade_count: count(t.id),
        total_size: sum(t.size),
        wins: count(fragment("CASE WHEN ? = true THEN 1 END", t.was_correct)),
        resolved: count(fragment("CASE WHEN ? IS NOT NULL THEN 1 END", t.was_correct))
      },
      order_by: [desc: count(t.id)],
      limit: 10
    )

    if length(markets) > 0 do
      Mix.shell().info("MARKETS TRADED (top 10)")

      markets
      |> Enum.with_index()
      |> Enum.each(fn {market, idx} ->
        prefix = if idx == length(markets) - 1, do: "└─", else: "├─"
        question = truncate(market.question || "Unknown", 40)
        outcome = if market.outcome_index == 0, do: "Yes", else: "No"
        size = ensure_float(market.total_size)

        win_str = if market.resolved > 0 do
          rate = market.wins / market.resolved * 100
          "#{round(rate)}% win"
        else
          "unresolved"
        end

        Mix.shell().info("#{prefix} #{question}")
        Mix.shell().info("   #{outcome} - #{market.trade_count} trades, $#{format_number(round(size))}, #{win_str}")
      end)

      Mix.shell().info("")
    end
  end

  defp print_top_trades(address, limit, verbose) do
    # Build base query without limit
    base_query = from t in Trade,
      join: ts in TradeScore, on: ts.trade_id == t.id,
      left_join: m in Market, on: m.id == t.market_id,
      where: t.wallet_address == ^address,
      order_by: [desc: ts.anomaly_score],
      select: %{
        trade_id: t.id,
        question: m.question,
        size: t.size,
        outcome_index: t.outcome_index,
        was_correct: t.was_correct,
        anomaly_score: ts.anomaly_score,
        insider_probability: ts.insider_probability,
        trinity_pattern: ts.trinity_pattern,
        trade_timestamp: t.trade_timestamp
      }

    # Apply limit only when not in verbose mode
    query = if verbose, do: base_query, else: from(q in base_query, limit: ^limit)
    trades = Repo.all(query)

    if length(trades) > 0 do
      Mix.shell().info("TOP SUSPICIOUS TRADES (by score)")

      trades
      |> Enum.with_index()
      |> Enum.each(fn {trade, idx} ->
        prefix = if idx == length(trades) - 1, do: "└─", else: "├─"
        question = truncate(trade.question || "Unknown", 35)
        size = ensure_float(trade.size)
        score = ensure_float(trade.anomaly_score)
        outcome = if trade.outcome_index == 0, do: "Yes", else: "No"

        correct_icon = case trade.was_correct do
          true -> "✅"
          false -> "❌"
          nil -> "⏳"
        end

        trinity = if trade.trinity_pattern, do: "⚡", else: ""

        Mix.shell().info("#{prefix} #{question}")
        Mix.shell().info("   $#{format_number(round(size))} on #{outcome} - Score: #{Float.round(score, 2)} #{correct_icon} #{trinity}")
      end)

      Mix.shell().info("")
    end
  end

  defp print_related_wallets(address) do
    # Find wallets that traded the same markets
    related = Repo.all(from t in Trade,
      join: t2 in Trade, on: t2.market_id == t.market_id and t2.wallet_address != t.wallet_address,
      join: ts2 in TradeScore, on: ts2.trade_id == t2.id,
      where: t.wallet_address == ^address,
      group_by: t2.wallet_address,
      having: count(t2.id) >= 3,  # At least 3 trades in same markets
      select: %{
        wallet_address: t2.wallet_address,
        shared_markets: count(fragment("DISTINCT ?", t2.market_id)),
        trade_count: count(t2.id),
        avg_score: avg(ts2.anomaly_score)
      },
      order_by: [desc: avg(ts2.anomaly_score)],
      limit: 10
    )

    high_score_related = Enum.filter(related, fn r ->
      ensure_float(r.avg_score) > 0.5
    end)

    if length(high_score_related) > 0 do
      Mix.shell().info("RELATED SUSPICIOUS WALLETS (same markets, score >0.5)")

      high_score_related
      |> Enum.with_index()
      |> Enum.each(fn {wallet, idx} ->
        prefix = if idx == length(high_score_related) - 1, do: "└─", else: "├─"
        short = format_wallet(wallet.wallet_address)
        avg = ensure_float(wallet.avg_score)

        Mix.shell().info("#{prefix} #{short} - #{wallet.shared_markets} shared markets, #{wallet.trade_count} trades, avg score: #{Float.round(avg, 2)}")
      end)

      Mix.shell().info("")
    end
  end

  defp print_footer(address) do
    Mix.shell().info(String.duplicate("─", 65))
    Mix.shell().info("Next steps:")
    Mix.shell().info("  • Find ring: mix polymarket.find_ring #{String.slice(address, 0, 12)}...")
    Mix.shell().info("  • View markets: mix polymarket.investigate_market <condition_id>")
    Mix.shell().info("")
  end

  defp output_json(address, profile, _opts) do
    # Build JSON output
    dist = Repo.one(from t in Trade,
      join: ts in TradeScore, on: ts.trade_id == t.id,
      where: t.wallet_address == ^address,
      select: %{
        total: count(ts.id),
        critical: count(fragment("CASE WHEN ?::numeric > 0.9 THEN 1 END", ts.anomaly_score)),
        high: count(fragment("CASE WHEN ?::numeric > 0.7 AND ?::numeric <= 0.9 THEN 1 END", ts.anomaly_score, ts.anomaly_score)),
        medium: count(fragment("CASE WHEN ?::numeric > 0.5 AND ?::numeric <= 0.7 THEN 1 END", ts.anomaly_score, ts.anomaly_score)),
        low: count(fragment("CASE WHEN ?::numeric > 0.3 AND ?::numeric <= 0.5 THEN 1 END", ts.anomaly_score, ts.anomaly_score)),
        normal: count(fragment("CASE WHEN ?::numeric <= 0.3 THEN 1 END", ts.anomaly_score))
      }
    )

    json = %{
      address: address,
      profile: profile,
      score_distribution: dist
    }

    Mix.shell().info(Jason.encode!(json, pretty: true))
  end

  defp return_early, do: :ok

  # Formatting helpers
  defp format_wallet(nil), do: "Unknown"
  defp format_wallet(address) when byte_size(address) > 10 do
    "#{String.slice(address, 0, 6)}...#{String.slice(address, -4, 4)}"
  end
  defp format_wallet(address), do: address

  defp format_number(n) when is_integer(n) do
    n
    |> Integer.to_string()
    |> String.reverse()
    |> String.replace(~r/(\d{3})(?=\d)/, "\\1,")
    |> String.reverse()
  end
  defp format_number(n) when is_float(n), do: format_number(round(n))
  defp format_number(n), do: "#{n}"

  defp format_profit(nil), do: "N/A"
  defp format_profit(n) when n >= 0, do: "+$#{format_number(round(n))}"
  defp format_profit(n), do: "-$#{format_number(round(abs(n)))}"

  defp format_datetime(nil), do: "N/A"
  defp format_datetime(%DateTime{} = dt) do
    Calendar.strftime(dt, "%Y-%m-%d %H:%M")
  end
  defp format_datetime(%NaiveDateTime{} = dt) do
    Calendar.strftime(dt, "%Y-%m-%d %H:%M")
  end

  defp format_scientific(p) when p < 0.0001 do
    exp = :math.log10(p) |> floor()
    "~10^#{exp}"
  end
  defp format_scientific(p), do: "#{Float.round(p, 6)}"

  defp truncate(nil, _), do: ""
  defp truncate(str, max) when is_binary(str) do
    if String.length(str) > max do
      String.slice(str, 0, max) <> "..."
    else
      str
    end
  end

  defp ensure_float(nil), do: 0.0
  defp ensure_float(%Decimal{} = d), do: Decimal.to_float(d)
  defp ensure_float(f) when is_float(f), do: f
  defp ensure_float(n) when is_integer(n), do: n * 1.0
end
