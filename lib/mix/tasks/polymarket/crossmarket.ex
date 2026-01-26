defmodule Mix.Tasks.Polymarket.Crossmarket do
  @moduledoc """
  Phase 3: Cross-market wallet scanning for insider detection.

  Scans wallets across multiple markets to find:
  1. Repeat offenders - confirmed insiders trading on other markets
  2. Similar patterns - wallets behaving like known insiders
  3. Wallet networks - clusters of wallets trading together suspiciously

  ## Commands

      # Scan confirmed insider wallets across all markets
      mix polymarket.crossmarket --scan-insiders

      # Find wallets with similar patterns to insiders
      mix polymarket.crossmarket --find-similar

      # Analyze a specific wallet's network
      mix polymarket.crossmarket --network 0x123...

      # Full scan: insiders + similar wallets
      mix polymarket.crossmarket --full

  ## Options

      --scan-insiders      Scan confirmed insider wallets across markets
      --find-similar       Find wallets with insider-like patterns
      --network WALLET     Analyze specific wallet's trading network
      --full               Run complete cross-market analysis

      --min-score FLOAT    Minimum suspicion score (default: 0.5)
      --min-markets INT    Minimum markets for similar wallet search (default: 2)
      --min-win-rate FLOAT Minimum win rate for similar search (default: 0.7)
      --limit INT          Maximum results (default: 50)

      --promote            Promote findings to investigation candidates
      --promote-limit INT  Max candidates to create (default: 20)

  ## Examples

      # Quick scan of known insider wallets
      mix polymarket.crossmarket --scan-insiders

      # Find suspicious wallets trading 3+ markets with 80%+ win rate
      mix polymarket.crossmarket --find-similar --min-markets 3 --min-win-rate 0.8

      # Full analysis with promotion
      mix polymarket.crossmarket --full --promote

      # Investigate specific wallet
      mix polymarket.crossmarket --network 0xbacd00c9080a82ded56f504ee8810af732b0ab35

  ## Workflow

      1. mix polymarket.crossmarket --scan-insiders    # Find insider activity on other markets
      2. mix polymarket.crossmarket --find-similar     # Find wallets with similar patterns
      3. mix polymarket.crossmarket --network 0x...    # Deep dive into suspicious wallet
      4. mix polymarket.crossmarket --full --promote   # Promote findings to candidates
      5. mix polymarket.feedback                       # Run feedback loop
  """

  use Mix.Task
  alias VolfefeMachine.Polymarket.CrossMarketScanner

  @shortdoc "Cross-market wallet scanning for insider detection"

  @impl Mix.Task
  def run(args) do
    Mix.Task.run("app.start")

    {opts, _, _} = OptionParser.parse(args,
      switches: [
        scan_insiders: :boolean,
        find_similar: :boolean,
        network: :string,
        full: :boolean,
        min_score: :float,
        min_markets: :integer,
        min_win_rate: :float,
        limit: :integer,
        promote: :boolean,
        promote_limit: :integer
      ],
      aliases: [
        s: :scan_insiders,
        f: :find_similar,
        n: :network,
        p: :promote,
        l: :limit
      ]
    )

    cond do
      opts[:full] ->
        run_full_analysis(opts)

      opts[:scan_insiders] ->
        scan_insider_wallets(opts)

      opts[:find_similar] ->
        find_similar_wallets(opts)

      opts[:network] ->
        analyze_network(opts[:network])

      true ->
        print_help()
    end
  end

  # ============================================================================
  # Commands
  # ============================================================================

  defp run_full_analysis(opts) do
    print_header("FULL CROSS-MARKET ANALYSIS")

    Mix.shell().info("Phase 1: Scanning insider wallets...")
    Mix.shell().info("")

    insider_results = case scan_insider_wallets(opts) do
      {:ok, results} -> results.suspicious_trades
      _ -> []
    end

    Mix.shell().info("")
    Mix.shell().info("Phase 2: Finding similar wallets...")
    Mix.shell().info("")

    similar_results = case find_similar_wallets_internal(opts) do
      {:ok, results} -> results.wallets
      _ -> []
    end

    # Combine and dedupe by wallet address
    all_suspicious = (insider_results ++ similar_results)
    |> Enum.uniq_by(& &1.wallet_address)
    |> Enum.sort_by(& &1.suspicion_score, :desc)

    Mix.shell().info("")
    print_divider()
    Mix.shell().info("COMBINED RESULTS: #{length(all_suspicious)} suspicious wallets")
    print_divider()
    Mix.shell().info("")

    if opts[:promote] && length(all_suspicious) > 0 do
      promote_limit = opts[:promote_limit] || 20
      min_score = opts[:min_score] || 0.6

      Mix.shell().info("Promoting top findings to candidates...")

      {:ok, result} = CrossMarketScanner.promote_to_candidates(all_suspicious,
        min_score: min_score,
        limit: promote_limit,
        batch_prefix: "crossmarket-full"
      )

      Mix.shell().info("")
      Mix.shell().info("Created #{result.candidates_created} investigation candidates")
      Mix.shell().info("Batch ID: #{result.batch_id}")
    end

    Mix.shell().info("")
    print_next_steps()
  end

  defp scan_insider_wallets(opts) do
    print_header("CROSS-MARKET INSIDER SCAN")

    min_score = opts[:min_score] || 0.5

    case CrossMarketScanner.scan_insider_wallets(min_score: min_score) do
      {:ok, results} ->
        print_scan_results(results)

        if opts[:promote] && length(results.suspicious_trades) > 0 do
          promote_results(results.suspicious_trades, opts, "crossmarket-insider")
        end

        {:ok, results}

      {:error, reason} ->
        Mix.shell().error("Scan failed: #{reason}")
        {:error, reason}
    end
  end

  defp find_similar_wallets(opts) do
    print_header("SIMILAR WALLET DETECTION")

    case find_similar_wallets_internal(opts) do
      {:ok, results} ->
        print_similar_results(results)

        if opts[:promote] && length(results.wallets) > 0 do
          promote_results(results.wallets, opts, "crossmarket-similar")
        end

        {:ok, results}
    end
  end

  defp find_similar_wallets_internal(opts) do
    min_markets = opts[:min_markets] || 2
    min_win_rate = opts[:min_win_rate] || 0.7
    limit = opts[:limit] || 50

    CrossMarketScanner.find_similar_wallets(
      min_markets: min_markets,
      min_win_rate: min_win_rate,
      limit: limit
    )
  end

  defp analyze_network(wallet_address) do
    print_header("WALLET NETWORK ANALYSIS")

    Mix.shell().info("Wallet: #{wallet_address}")
    Mix.shell().info("")

    case CrossMarketScanner.analyze_wallet_network(wallet_address) do
      {:ok, results} ->
        print_network_results(results)

      {:error, reason} ->
        Mix.shell().error("Analysis failed: #{reason}")
    end
  end

  # ============================================================================
  # Output Formatting
  # ============================================================================

  defp print_scan_results(results) do
    Mix.shell().info("Wallets Scanned:    #{results.wallets_scanned}")
    Mix.shell().info("Markets Analyzed:   #{results.markets_analyzed}")
    Mix.shell().info("Suspicious Trades:  #{length(results.suspicious_trades)}")
    Mix.shell().info("")

    if results.summary do
      Mix.shell().info("By Priority:")
      Enum.each(results.summary.by_priority, fn {priority, count} ->
        icon = priority_icon(priority)
        Mix.shell().info("  #{icon} #{String.capitalize(priority)}: #{count}")
      end)
    end

    if length(results.suspicious_trades) > 0 do
      Mix.shell().info("")
      print_divider()
      Mix.shell().info("TOP SUSPICIOUS ACTIVITY")
      print_divider()
      Mix.shell().info("")

      results.suspicious_trades
      |> Enum.take(10)
      |> Enum.with_index(1)
      |> Enum.each(&print_suspicious_trade/1)
    end
  end

  defp print_similar_results(results) do
    Mix.shell().info("Wallets Found:      #{results.wallets_found}")
    Mix.shell().info("Excluded (known):   #{results.excluded_count}")
    Mix.shell().info("")

    if length(results.wallets) > 0 do
      print_divider()
      Mix.shell().info("SUSPICIOUS WALLETS")
      print_divider()
      Mix.shell().info("")

      results.wallets
      |> Enum.take(15)
      |> Enum.with_index(1)
      |> Enum.each(&print_similar_wallet/1)
    else
      Mix.shell().info("No suspicious wallets found matching criteria.")
    end
  end

  defp print_network_results(results) do
    Mix.shell().info("Markets Traded:     #{results.markets_traded}")
    Mix.shell().info("Total Trades:       #{results.total_trades}")
    Mix.shell().info("Network Risk:       #{format_percent(results.network_risk_score)}")
    Mix.shell().info("")

    if length(results.market_details) > 0 do
      print_divider()
      Mix.shell().info("MARKET ACTIVITY")
      print_divider()
      Mix.shell().info("")

      results.market_details
      |> Enum.sort_by(& &1.total_volume, {:desc, Decimal})
      |> Enum.each(&print_market_detail/1)
    end

    if length(results.connected_wallets) > 0 do
      Mix.shell().info("")
      print_divider()
      Mix.shell().info("CONNECTED WALLETS (trade same markets)")
      print_divider()
      Mix.shell().info("")

      results.connected_wallets
      |> Enum.take(10)
      |> Enum.each(&print_connected_wallet/1)
    end
  end

  defp print_suspicious_trade({trade, idx}) do
    icon = priority_icon(trade.priority)
    wallet_short = format_wallet(trade.wallet_address)
    volume = format_money(trade.total_volume)
    score = format_percent(trade.suspicion_score)
    timing = format_timing(trade.hours_before_resolution)
    market = truncate(trade.market_question || "Unknown", 40)

    Mix.shell().info("#{icon} #{idx}. #{wallet_short}")
    Mix.shell().info("   Volume: #{volume} | Score: #{score} | #{timing}")
    Mix.shell().info("   Market: #{market}")
    Mix.shell().info("")
  end

  defp print_similar_wallet({wallet, idx}) do
    icon = priority_icon(wallet.priority)
    wallet_short = format_wallet(wallet.wallet_address)
    volume = format_money(wallet.total_volume)
    score = format_percent(wallet.suspicion_score)
    win_rate = format_percent(wallet.win_rate)
    markets = wallet.market_count

    Mix.shell().info("#{icon} #{idx}. #{wallet_short}")
    Mix.shell().info("   Markets: #{markets} | Volume: #{volume} | Win Rate: #{win_rate} | Score: #{score}")
    Mix.shell().info("")
  end

  defp print_market_detail(detail) do
    market = truncate(detail.market_question || detail.condition_id, 50)
    volume = format_money(detail.total_volume)
    win_rate = if detail.win_rate, do: format_percent(detail.win_rate), else: "N/A"
    trades = detail.trade_count

    Mix.shell().info("  #{market}")
    Mix.shell().info("  └─ #{trades} trades | #{volume} | Win rate: #{win_rate}")
    Mix.shell().info("")
  end

  defp print_connected_wallet(wallet) do
    wallet_short = format_wallet(wallet.wallet_address)
    overlap = format_percent(wallet.overlap_score)
    volume = format_money(wallet.total_volume)

    Mix.shell().info("  #{wallet_short} | Overlap: #{overlap} | Volume: #{volume}")
  end

  defp promote_results(items, opts, batch_prefix) do
    promote_limit = opts[:promote_limit] || 20
    min_score = opts[:min_score] || 0.6

    Mix.shell().info("")
    Mix.shell().info("Promoting to investigation candidates...")

    {:ok, result} = CrossMarketScanner.promote_to_candidates(items,
      min_score: min_score,
      limit: promote_limit,
      batch_prefix: batch_prefix
    )

    Mix.shell().info("Created #{result.candidates_created} candidates")
    Mix.shell().info("Batch ID: #{result.batch_id}")
  end

  # ============================================================================
  # Helpers
  # ============================================================================

  defp print_header(title) do
    Mix.shell().info("")
    Mix.shell().info(String.duplicate("=", 65))
    Mix.shell().info(title)
    Mix.shell().info(String.duplicate("=", 65))
    Mix.shell().info("")
  end

  defp print_divider do
    Mix.shell().info(String.duplicate("-", 65))
  end

  defp print_next_steps do
    Mix.shell().info("Next steps:")
    Mix.shell().info("  mix polymarket.candidates --status undiscovered  # View new candidates")
    Mix.shell().info("  mix polymarket.investigate --id ID               # Investigate candidate")
    Mix.shell().info("  mix polymarket.feedback                          # Run feedback loop")
    Mix.shell().info("")
  end

  defp print_help do
    Mix.shell().info("")
    Mix.shell().info("Cross-market wallet scanning for insider detection.")
    Mix.shell().info("")
    Mix.shell().info("Usage:")
    Mix.shell().info("  mix polymarket.crossmarket --scan-insiders    # Scan insider wallets")
    Mix.shell().info("  mix polymarket.crossmarket --find-similar     # Find similar wallets")
    Mix.shell().info("  mix polymarket.crossmarket --network 0x...    # Analyze wallet network")
    Mix.shell().info("  mix polymarket.crossmarket --full             # Full analysis")
    Mix.shell().info("")
    Mix.shell().info("Options:")
    Mix.shell().info("  --promote         Create investigation candidates from findings")
    Mix.shell().info("  --min-score 0.5   Minimum suspicion score")
    Mix.shell().info("  --min-markets 2   Minimum markets (for --find-similar)")
    Mix.shell().info("  --limit 50        Maximum results")
    Mix.shell().info("")
  end

  defp priority_icon("critical"), do: "🚨"
  defp priority_icon("high"), do: "⚠️"
  defp priority_icon("medium"), do: "📊"
  defp priority_icon(_), do: "ℹ️"

  defp format_wallet(nil), do: "Unknown"
  defp format_wallet(address) when byte_size(address) > 12 do
    "#{String.slice(address, 0, 6)}...#{String.slice(address, -4, 4)}"
  end
  defp format_wallet(address), do: address

  defp format_money(nil), do: "$0"
  defp format_money(%Decimal{} = d) do
    "$#{Decimal.round(d, 2) |> Decimal.to_string()}"
  end
  defp format_money(n), do: "$#{n}"

  defp format_percent(nil), do: "N/A"
  defp format_percent(n) when is_float(n), do: "#{Float.round(n * 100, 1)}%"
  defp format_percent(n), do: "#{n}%"

  defp format_timing(nil), do: "Timing: N/A"
  defp format_timing(hours) when hours <= 24, do: "#{Float.round(hours, 1)}h before"
  defp format_timing(hours) when hours <= 168, do: "#{Float.round(hours / 24, 1)}d before"
  defp format_timing(hours), do: "#{Float.round(hours / 168, 1)}w before"

  defp truncate(nil, _), do: "N/A"
  defp truncate(str, max) when is_binary(str) do
    if String.length(str) <= max, do: str, else: String.slice(str, 0, max - 3) <> "..."
  end
end
