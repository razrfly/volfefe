defmodule Mix.Tasks.Polymarket.Discover do
  @moduledoc """
  Run discovery to find insider candidates or market matches for reference cases.

  Supports two discovery modes:
  1. **Anomaly-based**: Scan scored trades for anomaly patterns (default)
  2. **Reference case**: Scan blockchain by date to discover markets for known events

  ## Usage

      # ANOMALY MODE: Quick discovery with defaults
      mix polymarket.discover
      mix polymarket.discover --anomaly 0.6 --probability 0.5

      # REFERENCE CASE MODE: Discover market for a known event
      mix polymarket.discover --reference-case "Nobel Peace Prize 2025"
      mix polymarket.discover --reference-case "Nobel Peace Prize 2025" --window 10 --top 15

      # Discover for ALL reference cases missing condition_ids
      mix polymarket.discover --all-references

  ## Anomaly Mode Options

      --anomaly       Anomaly score threshold (default: 0.5)
      --probability   Insider probability threshold (default: 0.4)
      --limit         Max candidates to generate (default: 100)
      --min-profit    Minimum estimated profit filter (default: 100)
      --notes         Notes for this discovery batch

  ## Reference Case Mode Options

      --reference-case NAME   Discover markets for specific reference case
      --all-references        Discover for all cases without condition_ids
      --window N              Days before event_date to scan (default: 7)
      --after N               Days after event_date to scan (default: 1)
      --top N                 Show top N candidate markets (default: 10)

  ## Reference Case Discovery Flow

      1. Look up reference case → get event_date
      2. Create date window (event_date - 7 days to event_date + 1 day)
      3. Scan ALL blockchain trades in that window
      4. Group trades by market, score by:
         - Volume near event_date
         - Whale activity (>$1K trades)
         - Trade concentration
      5. Output ranked candidates for human review
      6. User confirms correct market with: mix polymarket.confirm

  ## Examples

      $ mix polymarket.discover --reference-case "Nobel Peace Prize 2025"

      ═══════════════════════════════════════════════════════════════
      REFERENCE CASE DISCOVERY
      ═══════════════════════════════════════════════════════════════

      Reference Case: Nobel Peace Prize 2025
      Event Date: 2025-10-11
      Scan Window: 2025-10-04 to 2025-10-12

      Fetching trades from subgraph...
      Analyzing 15,234 trades across 156 markets...

      ─────────────────────────────────────────────────────────────────
      TOP 10 CANDIDATE MARKETS
      ─────────────────────────────────────────────────────────────────

      1. 0x14a3dfeba8b22a32fe... (Score: 0.89)
         Volume: $45,123 | Trades: 234 | Whales: 12
         Activity Peak: 2025-10-10 (1 day before event)

      2. 0x8bc4e2d1f3a5678901... (Score: 0.72)
         ...

      To confirm a match:
        mix polymarket.confirm --reference-case "Nobel Peace Prize 2025" --condition 0x14a3...
  """

  use Mix.Task
  require Logger
  import Ecto.Query
  alias VolfefeMachine.Polymarket
  alias VolfefeMachine.Polymarket.{SubgraphClient, TokenMapping, InsiderReferenceCase}
  alias VolfefeMachine.Repo

  @shortdoc "Run discovery to find insider candidates or market matches"

  @impl Mix.Task
  def run(args) do
    Mix.Task.run("app.start")

    {opts, _, _} = OptionParser.parse(args,
      switches: [
        # Anomaly mode
        anomaly: :float,
        probability: :float,
        limit: :integer,
        min_profit: :integer,
        notes: :string,
        # Reference case mode
        reference_case: :string,
        all_references: :boolean,
        window: :integer,
        after: :integer,
        top: :integer
      ],
      aliases: [a: :anomaly, p: :probability, l: :limit, n: :notes, r: :reference_case, t: :top]
    )

    cond do
      opts[:reference_case] ->
        discover_for_reference_case(opts[:reference_case], opts)

      opts[:all_references] ->
        discover_for_all_references(opts)

      true ->
        # Original anomaly-based discovery
        run_anomaly_discovery(opts)
    end
  end

  # ============================================
  # Reference Case Discovery Mode (Phase 2)
  # ============================================

  defp discover_for_reference_case(case_name, opts) do
    print_reference_header()

    # Look up reference case
    case Repo.get_by(InsiderReferenceCase, case_name: case_name) do
      nil ->
        Mix.shell().error("❌ Reference case not found: #{case_name}")
        Mix.shell().info("")
        Mix.shell().info("Available reference cases:")
        list_reference_cases()

      ref_case ->
        run_reference_discovery(ref_case, opts)
    end

    print_reference_footer()
  end

  defp discover_for_all_references(opts) do
    print_reference_header()

    # Get all Polymarket reference cases WITHOUT condition_ids
    cases = from(r in InsiderReferenceCase,
      where: r.platform == "polymarket" and is_nil(r.condition_id),
      where: not is_nil(r.event_date),
      order_by: r.event_date
    ) |> Repo.all()

    if length(cases) == 0 do
      Mix.shell().info("✅ All Polymarket reference cases already have condition_ids!")
      Mix.shell().info("")
      Mix.shell().info("To re-discover, first clear the condition_id:")
      Mix.shell().info("  iex> Repo.get_by(InsiderReferenceCase, case_name: \"...\") |> ...")
    else
      Mix.shell().info("Found #{length(cases)} reference cases without condition_ids:")
      Mix.shell().info("")

      Enum.each(cases, fn rc ->
        event_date = if rc.event_date, do: Date.to_string(rc.event_date), else: "N/A"
        Mix.shell().info("  • #{rc.case_name} (#{event_date})")
      end)

      Mix.shell().info("")
      Mix.shell().info(String.duplicate("─", 65))

      # Process each
      Enum.each(cases, fn rc ->
        Mix.shell().info("")
        run_reference_discovery(rc, opts)
        Mix.shell().info("")
      end)
    end

    print_reference_footer()
  end

  defp run_reference_discovery(ref_case, opts) do
    window_before = opts[:window] || 7
    window_after = opts[:after] || 1
    top_n = opts[:top] || 10

    Mix.shell().info("Reference Case: #{ref_case.case_name}")

    case ref_case.event_date do
      nil ->
        Mix.shell().error("   ❌ No event_date set for this reference case")
        Mix.shell().info("   Set it first, then re-run discovery")

      event_date ->
        from_date = Date.add(event_date, -window_before)
        to_date = Date.add(event_date, window_after)

        Mix.shell().info("Event Date: #{event_date}")
        Mix.shell().info("Scan Window: #{from_date} to #{to_date}")
        Mix.shell().info("")

        # Scan blockchain
        case scan_date_range(from_date, to_date) do
          {:ok, events, mapping} ->
            Mix.shell().info("Analyzing #{format_number(length(events))} trades...")
            Mix.shell().info("")

            # Score and rank markets
            candidates = score_markets_for_reference(events, mapping, event_date, ref_case)

            # Save discovery results to reference case (Phase 3)
            save_discovery_results(ref_case, candidates, %{
              window_before: window_before,
              window_after: window_after,
              from_date: Date.to_string(from_date),
              to_date: Date.to_string(to_date),
              total_trades: length(events),
              candidate_count: length(candidates)
            })

            # Display results
            display_candidates(candidates, top_n, ref_case)

          {:error, reason} ->
            Mix.shell().error("   ❌ Scan failed: #{reason}")
        end
    end
  end

  defp save_discovery_results(ref_case, candidates, meta) do
    # Collect all condition_ids
    condition_ids = candidates
    |> Enum.take(20)  # Top 20
    |> Enum.map(& &1.condition_id)
    |> Enum.filter(& &1 != nil)

    # Aggregate suspicious wallets across all candidates
    all_wallets = aggregate_suspicious_wallets(candidates)
    |> Enum.take(30)  # Top 30
    |> Enum.map(&serialize_wallet/1)

    # Build analysis notes
    top_candidate = Enum.at(candidates, 0)
    notes = if top_candidate do
      """
      Discovery run: #{DateTime.utc_now() |> DateTime.to_string()}
      Top candidate: #{top_candidate.condition_id}
      Top score: #{top_candidate.score}
      Total volume in top market: $#{format_decimal(top_candidate.total_volume)}
      Suspicious wallets found: #{length(all_wallets)}
      """
    else
      "Discovery run: #{DateTime.utc_now() |> DateTime.to_string()}\nNo candidates found."
    end

    # Update reference case
    attrs = %{
      discovered_condition_ids: condition_ids,
      discovered_wallets: all_wallets,
      analysis_notes: notes,
      discovery_run_at: DateTime.utc_now(),
      discovery_meta: meta
    }

    case ref_case |> Ecto.Changeset.change(attrs) |> Repo.update() do
      {:ok, _updated} ->
        Mix.shell().info("💾 Discovery results saved to reference case")
        Mix.shell().info("   • #{length(condition_ids)} candidate condition_ids")
        Mix.shell().info("   • #{length(all_wallets)} suspicious wallets")
        Mix.shell().info("")

      {:error, changeset} ->
        Mix.shell().error("⚠️  Failed to save discovery results:")
        Ecto.Changeset.traverse_errors(changeset, fn {msg, opts} ->
          Enum.reduce(opts, msg, fn {key, value}, acc ->
            String.replace(acc, "%{#{key}}", to_string(value))
          end)
        end)
        |> Enum.each(fn {field, errors} ->
          Mix.shell().error("   #{field}: #{Enum.join(errors, ", ")}")
        end)
    end
  end

  defp serialize_wallet(wallet) do
    %{
      "address" => wallet.address,
      "total_volume" => Decimal.to_string(wallet.total_volume),
      "trade_count" => wallet.trade_count,
      "whale_trade_count" => wallet.whale_trade_count,
      "pre_event_volume" => Decimal.to_string(wallet.pre_event_volume),
      "pre_event_trade_count" => wallet.pre_event_trade_count,
      "first_trade_at" => DateTime.to_string(wallet.first_trade_at),
      "last_trade_at" => DateTime.to_string(wallet.last_trade_at),
      "hours_before_event" => wallet.hours_before_event,
      "suspicion_score" => wallet.suspicion_score
    }
  end

  defp scan_date_range(from_date, to_date) do
    # Build token mapping
    {:ok, local_mapping} = TokenMapping.build_mapping(include_inactive: true)

    {:ok, subgraph_mapping} = SubgraphClient.build_subgraph_token_mapping(
      max_mappings: 50_000,
      progress_callback: fn %{fetched: f} ->
        if rem(f, 10_000) == 0 do
          Mix.shell().info("  Building mapping: #{f} tokens...")
        end
      end
    )

    combined_mapping = {local_mapping, subgraph_mapping}

    # Fetch trades
    from_ts = date_to_unix(from_date)
    to_ts = date_to_unix(to_date) + 86399

    Mix.shell().info("Fetching trades from subgraph...")

    case SubgraphClient.get_all_order_filled_events(
           from_timestamp: from_ts,
           to_timestamp: to_ts,
           max_events: 100_000,
           progress_callback: fn %{fetched: f, batch: _} ->
             if rem(f, 5000) == 0 do
               Mix.shell().info("  Fetched #{format_number(f)} trades...")
             end
           end
         ) do
      {:ok, events} ->
        Mix.shell().info("  ✅ Fetched #{format_number(length(events))} trades")
        {:ok, events, combined_mapping}

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp score_markets_for_reference(events, {local_mapping, subgraph_mapping}, event_date, ref_case) do
    # Group events by market (token_id)
    grouped = Enum.group_by(events, fn event ->
      token_id = event["makerAssetId"]
      if token_id == "0", do: event["takerAssetId"], else: token_id
    end)

    # Calculate scores for each market
    event_ts = date_to_unix(event_date)

    market_scores = Enum.map(grouped, fn {token_id, trades} ->
      # Get condition_id from mapping
      condition_id = case TokenMapping.lookup(local_mapping, token_id) do
        {:ok, %{condition_id: cid}} -> cid
        :not_found ->
          case Map.get(subgraph_mapping, token_id) do
            %{condition_id: cid} -> cid
            _ -> nil
          end
      end

      # Calculate metrics
      metrics = calculate_trade_metrics(trades, event_ts)

      # Calculate composite score
      score = calculate_discovery_score(metrics, ref_case)

      Map.merge(metrics, %{
        token_id: token_id,
        condition_id: condition_id,
        score: score
      })
    end)

    # Sort by score (highest first)
    market_scores
    |> Enum.filter(& &1.condition_id != nil)  # Only mapped markets
    |> Enum.sort_by(& &1.score, :desc)
  end

  defp calculate_trade_metrics(trades, event_ts) do
    # Total volume
    total_volume = Enum.reduce(trades, Decimal.new(0), fn trade, acc ->
      maker_amount = parse_amount(trade["makerAmountFilled"])
      taker_amount = parse_amount(trade["takerAmountFilled"])
      usdc = Decimal.min(maker_amount, taker_amount)
      Decimal.add(acc, usdc)
    end)

    # Unique wallets
    wallets = Enum.flat_map(trades, fn t -> [t["maker"], t["taker"]] end)
              |> Enum.uniq()

    # Whale trades (>$1K)
    whale_trades = Enum.filter(trades, fn trade ->
      maker_amount = parse_amount(trade["makerAmountFilled"])
      taker_amount = parse_amount(trade["takerAmountFilled"])
      usdc = Decimal.min(maker_amount, taker_amount)
      Decimal.compare(usdc, Decimal.new(1000)) == :gt
    end)

    # Volume in last 24h before event
    pre_event_start = event_ts - 86400  # 24h before
    pre_event_trades = Enum.filter(trades, fn t ->
      ts = String.to_integer(t["timestamp"])
      ts >= pre_event_start and ts < event_ts
    end)

    pre_event_volume = Enum.reduce(pre_event_trades, Decimal.new(0), fn trade, acc ->
      maker_amount = parse_amount(trade["makerAmountFilled"])
      taker_amount = parse_amount(trade["takerAmountFilled"])
      usdc = Decimal.min(maker_amount, taker_amount)
      Decimal.add(acc, usdc)
    end)

    # Activity peak (day with most volume)
    trades_by_day = Enum.group_by(trades, fn t ->
      ts = String.to_integer(t["timestamp"])
      DateTime.from_unix!(ts) |> DateTime.to_date()
    end)

    peak_day = trades_by_day
    |> Enum.map(fn {day, day_trades} ->
      day_vol = Enum.reduce(day_trades, Decimal.new(0), fn trade, acc ->
        maker_amount = parse_amount(trade["makerAmountFilled"])
        taker_amount = parse_amount(trade["takerAmountFilled"])
        usdc = Decimal.min(maker_amount, taker_amount)
        Decimal.add(acc, usdc)
      end)
      {day, day_vol}
    end)
    |> Enum.max_by(fn {_, vol} -> vol end, fn -> {nil, Decimal.new(0)} end)
    |> elem(0)

    # Analyze suspicious wallets (Phase 3)
    suspicious_wallets = analyze_suspicious_wallets(trades, event_ts)

    %{
      trade_count: length(trades),
      total_volume: total_volume,
      unique_wallets: length(wallets),
      whale_count: length(whale_trades),
      whale_volume: Enum.reduce(whale_trades, Decimal.new(0), fn trade, acc ->
        maker_amount = parse_amount(trade["makerAmountFilled"])
        taker_amount = parse_amount(trade["takerAmountFilled"])
        usdc = Decimal.min(maker_amount, taker_amount)
        Decimal.add(acc, usdc)
      end),
      pre_event_volume: pre_event_volume,
      pre_event_trades: length(pre_event_trades),
      peak_day: peak_day,
      suspicious_wallets: suspicious_wallets
    }
  end

  # ============================================
  # Wallet Analysis (Phase 3)
  # ============================================

  # Analyze trades to identify suspicious wallets.
  #
  # Scoring based on:
  # - Total volume (higher = more suspicious if other signals present)
  # - Whale trades (>$1K positions)
  # - Pre-event concentration (% of volume placed before event)
  # - Timing precision (activity closest to event)
  defp analyze_suspicious_wallets(trades, event_ts) do
    # Group trades by wallet (both maker and taker)
    wallet_trades = trades
    |> Enum.flat_map(fn trade ->
      amount = get_trade_amount(trade)
      ts = String.to_integer(trade["timestamp"])
      [
        {trade["maker"], %{amount: amount, timestamp: ts, side: :maker}},
        {trade["taker"], %{amount: amount, timestamp: ts, side: :taker}}
      ]
    end)
    |> Enum.group_by(fn {wallet, _} -> wallet end, fn {_, data} -> data end)

    # Analyze each wallet
    pre_event_window = event_ts - (7 * 86400)  # 7 days before event

    wallet_trades
    |> Enum.map(fn {wallet, wallet_data} ->
      analyze_wallet(wallet, wallet_data, event_ts, pre_event_window)
    end)
    |> Enum.filter(fn w -> w.suspicion_score > 0.3 end)  # Only keep somewhat suspicious
    |> Enum.sort_by(& &1.suspicion_score, :desc)
    |> Enum.take(20)  # Top 20 suspicious wallets per market
  end

  defp analyze_wallet(wallet, trades, event_ts, pre_event_window) do
    total_volume = trades
    |> Enum.map(& &1.amount)
    |> Enum.reduce(Decimal.new(0), &Decimal.add/2)

    # Whale trades (>$1K)
    whale_trades = Enum.filter(trades, fn t ->
      Decimal.compare(t.amount, Decimal.new(1000)) == :gt
    end)

    # Pre-event trades (before event but within window)
    pre_event_trades = Enum.filter(trades, fn t ->
      t.timestamp >= pre_event_window and t.timestamp < event_ts
    end)

    pre_event_volume = pre_event_trades
    |> Enum.map(& &1.amount)
    |> Enum.reduce(Decimal.new(0), &Decimal.add/2)

    # Find earliest and latest trade timestamps
    timestamps = Enum.map(trades, & &1.timestamp)
    first_trade = Enum.min(timestamps, fn -> event_ts end)
    last_trade = Enum.max(timestamps, fn -> event_ts end)

    # Calculate hours before event for last pre-event trade
    pre_event_timestamps = Enum.filter(timestamps, & &1 < event_ts)
    hours_before_event = if Enum.empty?(pre_event_timestamps) do
      nil
    else
      latest_pre_event = Enum.max(pre_event_timestamps)
      Float.round((event_ts - latest_pre_event) / 3600, 1)
    end

    # Calculate suspicion score
    suspicion_score = calculate_wallet_suspicion_score(
      total_volume,
      length(whale_trades),
      pre_event_volume,
      total_volume,
      hours_before_event
    )

    %{
      address: wallet,
      total_volume: total_volume,
      trade_count: length(trades),
      whale_trade_count: length(whale_trades),
      pre_event_volume: pre_event_volume,
      pre_event_trade_count: length(pre_event_trades),
      first_trade_at: DateTime.from_unix!(first_trade),
      last_trade_at: DateTime.from_unix!(last_trade),
      hours_before_event: hours_before_event,
      suspicion_score: suspicion_score
    }
  end

  defp calculate_wallet_suspicion_score(total_volume, whale_count, pre_event_vol, total_vol, hours_before) do
    # Volume score (log-scaled, higher for larger positions)
    vol_float = Decimal.to_float(total_volume)
    volume_score = min(:math.log10(max(vol_float, 1)) / 4.0, 1.0) * 0.25

    # Whale activity score
    whale_score = min(whale_count / 3.0, 1.0) * 0.25

    # Pre-event concentration score
    pre_event_ratio = if Decimal.compare(total_vol, Decimal.new(0)) == :gt do
      Decimal.div(pre_event_vol, total_vol) |> Decimal.to_float()
    else
      0.0
    end
    timing_concentration_score = pre_event_ratio * 0.30

    # Timing precision score (closer to event = more suspicious)
    timing_precision_score = case hours_before do
      nil -> 0.0
      h when h <= 24 -> 0.20  # Within 24h
      h when h <= 48 -> 0.15  # Within 48h
      h when h <= 72 -> 0.10  # Within 72h
      _ -> 0.05
    end

    Float.round(volume_score + whale_score + timing_concentration_score + timing_precision_score, 4)
  end

  defp get_trade_amount(trade) do
    maker_amount = parse_amount(trade["makerAmountFilled"])
    taker_amount = parse_amount(trade["takerAmountFilled"])
    Decimal.min(maker_amount, taker_amount)
  end

  defp calculate_discovery_score(metrics, _ref_case) do
    # Scoring weights (tuned for insider detection)
    #
    # Higher scores for:
    # - More whale activity (suggests informed money)
    # - Higher pre-event volume concentration
    # - More unique wallets (wider knowledge)
    # - Higher total volume (significant market)

    whale_score = min(metrics.whale_count / 10.0, 1.0) * 0.3

    # Pre-event volume as % of total
    pre_event_ratio = if Decimal.compare(metrics.total_volume, Decimal.new(0)) == :gt do
      Decimal.div(metrics.pre_event_volume, metrics.total_volume)
      |> Decimal.to_float()
    else
      0.0
    end
    timing_score = pre_event_ratio * 0.3

    # Volume score (log scale, capped)
    volume_float = Decimal.to_float(metrics.total_volume)
    volume_score = min(:math.log10(max(volume_float, 1)) / 5.0, 1.0) * 0.25

    # Wallet diversity score
    wallet_score = min(metrics.unique_wallets / 50.0, 1.0) * 0.15

    # Combine
    Float.round(whale_score + timing_score + volume_score + wallet_score, 4)
  end

  defp display_candidates(candidates, top_n, ref_case) do
    top = Enum.take(candidates, top_n)

    if length(top) == 0 do
      Mix.shell().info("⚠️  No candidate markets found in this date range")
      Mix.shell().info("")
      Mix.shell().info("Try expanding the window:")
      Mix.shell().info("  mix polymarket.discover --reference-case \"#{ref_case.case_name}\" --window 14")
    else
      Mix.shell().info(String.duplicate("─", 65))
      Mix.shell().info("TOP #{length(top)} CANDIDATE MARKETS")
      Mix.shell().info(String.duplicate("─", 65))
      Mix.shell().info("")

      Enum.with_index(top, 1) |> Enum.each(fn {market, rank} ->
        cond_short = truncate(market.condition_id, 24) <> "..."

        Mix.shell().info("#{rank}. #{cond_short} (Score: #{market.score})")
        Mix.shell().info("   Volume: $#{format_decimal(market.total_volume)} | Trades: #{format_number(market.trade_count)} | Whales: #{market.whale_count}")
        Mix.shell().info("   Wallets: #{market.unique_wallets} | Pre-event vol: $#{format_decimal(market.pre_event_volume)}")
        if market.peak_day do
          Mix.shell().info("   Peak activity: #{market.peak_day}")
        end

        # Show top suspicious wallets for this market (Phase 3)
        suspicious = Map.get(market, :suspicious_wallets, [])
        if length(suspicious) > 0 do
          top_wallets = Enum.take(suspicious, 3)
          Mix.shell().info("   🔍 Top suspicious wallets:")
          Enum.each(top_wallets, fn w ->
            wallet_short = truncate(w.address, 10) <> "..."
            hours = if w.hours_before_event, do: "#{w.hours_before_event}h before", else: "N/A"
            Mix.shell().info("      #{wallet_short} | $#{format_decimal(w.total_volume)} | Score: #{w.suspicion_score} | #{hours}")
          end)
        end

        Mix.shell().info("")
      end)

      # Aggregate suspicious wallets across all top markets
      all_suspicious = aggregate_suspicious_wallets(top)
      if length(all_suspicious) > 0 do
        Mix.shell().info(String.duplicate("─", 65))
        Mix.shell().info("TOP SUSPICIOUS WALLETS (across all candidates)")
        Mix.shell().info(String.duplicate("─", 65))
        Mix.shell().info("")

        Enum.with_index(Enum.take(all_suspicious, 10), 1) |> Enum.each(fn {w, rank} ->
          wallet_short = truncate(w.address, 14)
          hours = if w.hours_before_event, do: "#{w.hours_before_event}h before event", else: "timing N/A"
          Mix.shell().info("#{rank}. #{wallet_short}... (Score: #{w.suspicion_score})")
          Mix.shell().info("   Volume: $#{format_decimal(w.total_volume)} | Whale trades: #{w.whale_trade_count} | #{hours}")
        end)
        Mix.shell().info("")
      end

      Mix.shell().info(String.duplicate("─", 65))
      Mix.shell().info("")
      Mix.shell().info("To confirm a match (includes wallet discovery data), run:")
      Mix.shell().info("  mix polymarket.confirm --reference-case \"#{ref_case.case_name}\" \\")
      Mix.shell().info("    --condition #{Enum.at(top, 0).condition_id}")
    end
  end

  defp aggregate_suspicious_wallets(candidates) do
    # Collect all wallets from all candidates, dedupe by address, keep highest score
    candidates
    |> Enum.flat_map(fn c -> Map.get(c, :suspicious_wallets, []) end)
    |> Enum.group_by(& &1.address)
    |> Enum.map(fn {_addr, wallets} ->
      # Keep the wallet entry with highest suspicion score
      Enum.max_by(wallets, & &1.suspicion_score)
    end)
    |> Enum.sort_by(& &1.suspicion_score, :desc)
  end

  defp list_reference_cases do
    cases = from(r in InsiderReferenceCase,
      where: r.platform == "polymarket",
      order_by: r.event_date
    ) |> Repo.all()

    Enum.each(cases, fn rc ->
      event_date = if rc.event_date, do: Date.to_string(rc.event_date), else: "N/A"
      status = if rc.condition_id, do: "✅", else: "⬜"
      Mix.shell().info("  #{status} #{rc.case_name} (#{event_date})")
    end)
  end

  # ============================================
  # Anomaly-based Discovery Mode (Original)
  # ============================================

  defp run_anomaly_discovery(opts) do
    print_header()

    anomaly = opts[:anomaly] || 0.5
    probability = opts[:probability] || 0.4
    limit = opts[:limit] || 100
    min_profit = opts[:min_profit] || 100
    notes = opts[:notes] || "CLI discovery run"

    Mix.shell().info("Starting discovery batch...")
    Mix.shell().info("")

    Mix.shell().info("Parameters:")
    Mix.shell().info("├─ Anomaly Threshold:     #{anomaly}")
    Mix.shell().info("├─ Probability Threshold: #{probability}")
    Mix.shell().info("├─ Limit:                 #{limit}")
    Mix.shell().info("└─ Min Profit:            $#{min_profit}")
    Mix.shell().info("")

    Mix.shell().info("Processing...")

    discovery_opts = [
      anomaly_threshold: Decimal.from_float(anomaly),
      probability_threshold: Decimal.from_float(probability),
      limit: limit,
      min_profit: min_profit,
      notes: notes
    ]

    case Polymarket.quick_discovery(discovery_opts) do
      {:ok, result} ->
        batch = result.batch
        Mix.shell().info("")
        Mix.shell().info("✅ Discovery complete!")
        Mix.shell().info("   Batch ID: #{batch.batch_id}")
        Mix.shell().info("   Candidates Found: #{result.candidates_created}")

        if result.candidates_created > 0 do
          Mix.shell().info("   Top Score: #{format_decimal(batch.top_candidate_score)}")
          Mix.shell().info("   Median Score: #{format_decimal(batch.median_candidate_score)}")
        end

        Mix.shell().info("")

        if result.candidates_created > 0 do
          Mix.shell().info("Next steps:")
          Mix.shell().info("- View candidates: mix polymarket.candidates")
          Mix.shell().info("- Investigate: mix polymarket.investigate --id ID")
        else
          Mix.shell().info("No new candidates found matching criteria.")
          Mix.shell().info("Try lowering thresholds or running feedback loop first.")
        end

        Mix.shell().info("")

      {:error, reason} ->
        Mix.shell().error("")
        Mix.shell().error("❌ Discovery failed: #{inspect(reason)}")
        Mix.shell().info("")
    end

    print_footer()
  end

  # ============================================
  # Helpers
  # ============================================

  defp print_header do
    Mix.shell().info("")
    Mix.shell().info(String.duplicate("═", 65))
    Mix.shell().info("POLYMARKET DISCOVERY")
    Mix.shell().info(String.duplicate("═", 65))
    Mix.shell().info("")
  end

  defp print_footer do
    Mix.shell().info(String.duplicate("─", 65))
  end

  defp print_reference_header do
    Mix.shell().info("")
    Mix.shell().info(String.duplicate("═", 65))
    Mix.shell().info("REFERENCE CASE DISCOVERY")
    Mix.shell().info(String.duplicate("═", 65))
    Mix.shell().info("")
  end

  defp print_reference_footer do
    Mix.shell().info(String.duplicate("─", 65))
    Mix.shell().info("Use --window N to expand search range")
    Mix.shell().info("Use --top N to see more candidates")
    Mix.shell().info("")
  end

  defp format_decimal(nil), do: "N/A"
  defp format_decimal(%Decimal{} = d) do
    d
    |> Decimal.round(2)
    |> Decimal.to_string()
    |> String.replace(~r/(\d)(?=(\d{3})+(?!\d))/, "\\1,")
  end
  defp format_decimal(f) when is_float(f), do: Float.round(f, 4) |> Float.to_string()
  defp format_decimal(n), do: "#{n}"

  defp format_number(n) when is_integer(n) do
    n
    |> Integer.to_string()
    |> String.reverse()
    |> String.replace(~r/(\d{3})(?=\d)/, "\\1,")
    |> String.reverse()
  end
  defp format_number(n), do: "#{n}"

  defp truncate(nil, _), do: ""
  defp truncate(str, max_length) when is_binary(str) do
    if String.length(str) > max_length do
      String.slice(str, 0, max_length)
    else
      str
    end
  end

  defp date_to_unix(date) do
    date
    |> DateTime.new!(~T[00:00:00], "Etc/UTC")
    |> DateTime.to_unix()
  end

  defp parse_amount(nil), do: Decimal.new(0)
  defp parse_amount(str) when is_binary(str) do
    case Integer.parse(str) do
      {amount, _} -> Decimal.div(Decimal.new(amount), Decimal.new(1_000_000))
      :error -> Decimal.new(0)
    end
  end
end
