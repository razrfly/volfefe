defmodule Mix.Tasks.Polymarket.InvestigateMarket do
  @moduledoc """
  Deep investigation of a market by condition ID.

  Provides comprehensive analysis including market details, score distribution,
  top suspicious wallets, and trade timeline.

  ## Usage

      # Investigate by condition_id
      mix polymarket.investigate_market 0xabc123...

      # Investigate by market_id (database ID)
      mix polymarket.investigate_market --id 42

      # Show verbose output
      mix polymarket.investigate_market 0xabc123... --verbose

  ## Options

      --id        Market ID (database ID, alternative to condition_id)
      --verbose   Show all trades (default: top 20)
      --limit     Limit trades shown (default: 20)
      --json      Output as JSON

  ## Examples

      $ mix polymarket.investigate_market 0x123...

      MARKET INVESTIGATION
      ═══════════════════════════════════════════════════════════════

      MARKET: Will Elon Musk post 280-299 tweets from Jan 13-19?

      DETAILS
      ├─ Condition ID: 0x123...abc
      ├─ Category:     entertainment
      ├─ End Date:     2025-01-19
      ├─ Resolution:   Yes (resolved 2025-01-20)
      ├─ Volume:       $45,230
      └─ Liquidity:    $12,000

      SCORE DISTRIBUTION (156 trades)
      ├─ 🚨 Critical (>0.9): 12
      ├─ 🔴 High (>0.7):     34
      ├─ 🟠 Medium (>0.5):   56
      └─ ...

      TOP SUSPICIOUS WALLETS
      ├─ 0x5113...f0ba - 5 trades, 100% wins, avg score: 0.72
      ├─ 0xa4bd...e8a2 - 12 trades, 91% wins, avg score: 0.68
      └─ ...
  """

  use Mix.Task
  import Ecto.Query
  alias VolfefeMachine.Repo
  alias VolfefeMachine.Polymarket.{Trade, TradeScore, Market}

  @shortdoc "Deep investigation of a market"

  @impl Mix.Task
  def run(args) do
    Mix.Task.run("app.start")

    {opts, positional, _} = OptionParser.parse(args,
      switches: [
        id: :integer,
        verbose: :boolean,
        limit: :integer,
        json: :boolean
      ],
      aliases: [v: :verbose, l: :limit, j: :json]
    )

    cond do
      opts[:id] ->
        investigate_by_id(opts[:id], opts)

      length(positional) > 0 ->
        [condition_id | _] = positional
        investigate_by_condition_id(condition_id, opts)

      true ->
        Mix.shell().error("Error: condition_id or --id is required")
        Mix.shell().info("Usage: mix polymarket.investigate_market <condition_id> [options]")
        Mix.shell().info("       mix polymarket.investigate_market --id <market_id> [options]")
    end
  end

  defp investigate_by_id(id, opts) do
    case Repo.get(Market, id) do
      nil ->
        Mix.shell().error("Market with ID #{id} not found")

      market ->
        investigate(market, opts)
    end
  end

  defp investigate_by_condition_id(condition_id, opts) do
    # Try to find market by condition_id
    case Repo.get_by(Market, condition_id: condition_id) do
      nil ->
        # Try partial match
        market = Repo.one(from m in Market,
          where: ilike(m.condition_id, ^"#{condition_id}%"),
          limit: 1
        )

        if market do
          investigate(market, opts)
        else
          Mix.shell().error("Market with condition_id #{condition_id} not found")
        end

      market ->
        investigate(market, opts)
    end
  end

  defp investigate(market, opts) do
    limit = opts[:limit] || 20

    if opts[:json] do
      output_json(market, opts)
    else
      output_formatted(market, limit, opts[:verbose] || false)
    end
  end

  defp output_formatted(market, limit, verbose) do
    print_header(market)
    print_details(market)
    print_score_distribution(market)
    print_trade_stats(market)
    print_top_wallets(market, limit)
    print_recent_trades(market, limit, verbose)
    print_footer(market)
  end

  defp print_header(market) do
    Mix.shell().info("")
    Mix.shell().info("MARKET INVESTIGATION")
    Mix.shell().info(String.duplicate("═", 65))
    Mix.shell().info("")
    Mix.shell().info("MARKET: #{truncate(market.question, 55)}")
    Mix.shell().info("")
  end

  defp print_details(market) do
    Mix.shell().info("DETAILS")
    Mix.shell().info("├─ Database ID:   #{market.id}")
    Mix.shell().info("├─ Condition ID:  #{truncate(market.condition_id, 40)}")
    Mix.shell().info("├─ Category:      #{market.category}")

    if market.end_date do
      Mix.shell().info("├─ End Date:      #{format_date(market.end_date)}")
    end

    resolution_str = case market.resolved_outcome do
      nil -> "Not resolved"
      outcome -> "#{outcome} (resolved #{format_date(market.resolution_date)})"
    end
    Mix.shell().info("├─ Resolution:    #{resolution_str}")

    if market.volume do
      Mix.shell().info("├─ Total Volume:  $#{format_number(decimal_to_int(market.volume))}")
    end

    if market.liquidity do
      Mix.shell().info("└─ Liquidity:     $#{format_number(decimal_to_int(market.liquidity))}")
    else
      Mix.shell().info("└─ Liquidity:     N/A")
    end

    Mix.shell().info("")
  end

  defp print_score_distribution(market) do
    dist = Repo.one(from t in Trade,
      join: ts in TradeScore, on: ts.trade_id == t.id,
      where: t.market_id == ^market.id,
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
      Mix.shell().info("SCORE DISTRIBUTION (#{format_number(dist.total)} scored trades)")
      Mix.shell().info("├─ 🚨 Critical (>0.9): #{dist.critical}")
      Mix.shell().info("├─ 🔴 High (>0.7):     #{dist.high}")
      Mix.shell().info("├─ 🟠 Medium (>0.5):   #{dist.medium}")
      Mix.shell().info("├─ 🟡 Low (>0.3):      #{dist.low}")
      Mix.shell().info("├─ 🟢 Normal (≤0.3):   #{dist.normal}")
      Mix.shell().info("└─ ⚡ Trinity Pattern: #{dist.trinity_count}")
      Mix.shell().info("")
    else
      Mix.shell().info("SCORE DISTRIBUTION")
      Mix.shell().info("└─ No scored trades in this market")
      Mix.shell().info("")
    end
  end

  defp print_trade_stats(market) do
    stats = Repo.one(from t in Trade,
      where: t.market_id == ^market.id,
      select: %{
        total_trades: count(t.id),
        unique_wallets: count(fragment("DISTINCT ?", t.wallet_address)),
        total_volume: sum(t.size),
        avg_size: avg(t.size),
        resolved: count(fragment("CASE WHEN ? IS NOT NULL THEN 1 END", t.was_correct)),
        correct: count(fragment("CASE WHEN ? = true THEN 1 END", t.was_correct)),
        buy_count: count(fragment("CASE WHEN ? = 'BUY' THEN 1 END", t.side)),
        sell_count: count(fragment("CASE WHEN ? = 'SELL' THEN 1 END", t.side))
      }
    )

    if stats && stats.total_trades > 0 do
      Mix.shell().info("TRADE STATISTICS")
      Mix.shell().info("├─ Total Trades:    #{format_number(stats.total_trades)}")
      Mix.shell().info("├─ Unique Wallets:  #{format_number(stats.unique_wallets)}")
      Mix.shell().info("├─ Total Volume:    $#{format_number(decimal_to_int(stats.total_volume))}")
      Mix.shell().info("├─ Avg Trade Size:  $#{format_number(decimal_to_int(stats.avg_size))}")
      Mix.shell().info("├─ BUY/SELL:        #{stats.buy_count}/#{stats.sell_count}")

      if stats.resolved > 0 do
        win_rate = stats.correct / stats.resolved * 100
        Mix.shell().info("└─ Market Win Rate: #{Float.round(win_rate, 1)}% (#{stats.correct}/#{stats.resolved})")
      else
        Mix.shell().info("└─ Market Win Rate: N/A (not resolved)")
      end

      Mix.shell().info("")
    end
  end

  defp print_top_wallets(market, limit) do
    # Get top wallets by average score, with at least 2 trades
    wallets = Repo.all(from t in Trade,
      join: ts in TradeScore, on: ts.trade_id == t.id,
      where: t.market_id == ^market.id,
      group_by: t.wallet_address,
      having: count(t.id) >= 2,
      select: %{
        wallet_address: t.wallet_address,
        trade_count: count(t.id),
        total_size: sum(t.size),
        avg_score: avg(ts.anomaly_score),
        max_score: max(ts.anomaly_score),
        wins: count(fragment("CASE WHEN ? = true THEN 1 END", t.was_correct)),
        resolved: count(fragment("CASE WHEN ? IS NOT NULL THEN 1 END", t.was_correct))
      },
      order_by: [desc: avg(ts.anomaly_score)],
      limit: ^limit
    )

    if length(wallets) > 0 do
      suspicious = Enum.filter(wallets, fn w -> ensure_float(w.avg_score) > 0.5 end)

      if length(suspicious) > 0 do
        Mix.shell().info("TOP SUSPICIOUS WALLETS (avg score >0.5)")

        suspicious
        |> Enum.with_index()
        |> Enum.each(fn {wallet, idx} ->
          prefix = if idx == length(suspicious) - 1, do: "└─", else: "├─"
          short = format_wallet(wallet.wallet_address)
          avg = ensure_float(wallet.avg_score)
          volume = decimal_to_int(wallet.total_size)

          win_str = if wallet.resolved > 0 do
            rate = wallet.wins / wallet.resolved * 100
            "#{round(rate)}% win"
          else
            "unresolved"
          end

          Mix.shell().info("#{prefix} #{short} - #{wallet.trade_count} trades, $#{format_number(volume)}, #{win_str}, avg: #{Float.round(avg, 2)}")
        end)

        Mix.shell().info("")
      else
        Mix.shell().info("TOP WALLETS")
        Mix.shell().info("└─ No wallets with avg score >0.5")
        Mix.shell().info("")
      end
    end
  end

  defp print_recent_trades(market, limit, _verbose) do
    trades = Repo.all(from t in Trade,
      join: ts in TradeScore, on: ts.trade_id == t.id,
      where: t.market_id == ^market.id,
      order_by: [desc: ts.anomaly_score],
      limit: ^limit,
      select: %{
        trade_id: t.id,
        wallet_address: t.wallet_address,
        size: t.size,
        side: t.side,
        outcome_index: t.outcome_index,
        price: t.price,
        was_correct: t.was_correct,
        anomaly_score: ts.anomaly_score,
        insider_probability: ts.insider_probability,
        trinity_pattern: ts.trinity_pattern,
        trade_timestamp: t.trade_timestamp
      }
    )

    if length(trades) > 0 do
      Mix.shell().info("TOP SUSPICIOUS TRADES (by score)")

      trades
      |> Enum.with_index()
      |> Enum.each(fn {trade, idx} ->
        prefix = if idx == length(trades) - 1, do: "└─", else: "├─"
        short = format_wallet(trade.wallet_address)
        size = ensure_float(trade.size)
        score = ensure_float(trade.anomaly_score)
        price = ensure_float(trade.price)
        outcome = if trade.outcome_index == 0, do: "Yes", else: "No"

        correct_icon = case trade.was_correct do
          true -> "✅"
          false -> "❌"
          nil -> "⏳"
        end

        trinity = if trade.trinity_pattern, do: "⚡", else: ""

        Mix.shell().info("#{prefix} #{short} - $#{format_number(round(size))} #{trade.side} #{outcome} @#{Float.round(price, 2)}")
        Mix.shell().info("   Score: #{Float.round(score, 2)} #{correct_icon} #{trinity} | #{format_datetime(trade.trade_timestamp)}")
      end)

      Mix.shell().info("")
    end
  end

  defp print_footer(market) do
    Mix.shell().info(String.duplicate("─", 65))
    Mix.shell().info("Next steps:")
    Mix.shell().info("  • Investigate wallet: mix polymarket.investigate_wallet <address>")
    Mix.shell().info("  • Find ring: mix polymarket.find_ring #{truncate(market.condition_id, 12)}...")
    Mix.shell().info("")
  end

  defp output_json(market, _opts) do
    dist = Repo.one(from t in Trade,
      join: ts in TradeScore, on: ts.trade_id == t.id,
      where: t.market_id == ^market.id,
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
      market: %{
        id: market.id,
        condition_id: market.condition_id,
        question: market.question,
        category: market.category,
        resolved_outcome: market.resolved_outcome,
        volume: market.volume && Decimal.to_float(market.volume)
      },
      score_distribution: dist
    }

    Mix.shell().info(Jason.encode!(json, pretty: true))
  end

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
  defp format_number(nil), do: "0"
  defp format_number(n), do: "#{n}"

  defp format_date(nil), do: "N/A"
  defp format_date(%DateTime{} = dt), do: Calendar.strftime(dt, "%Y-%m-%d")
  defp format_date(%NaiveDateTime{} = dt), do: Calendar.strftime(dt, "%Y-%m-%d")

  defp format_datetime(nil), do: "N/A"
  defp format_datetime(%DateTime{} = dt), do: Calendar.strftime(dt, "%Y-%m-%d %H:%M")
  defp format_datetime(%NaiveDateTime{} = dt), do: Calendar.strftime(dt, "%Y-%m-%d %H:%M")

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

  defp decimal_to_int(nil), do: 0
  defp decimal_to_int(%Decimal{} = d), do: Decimal.to_integer(Decimal.round(d, 0))
  defp decimal_to_int(n) when is_number(n), do: round(n)
end
