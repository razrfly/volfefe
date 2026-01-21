defmodule Mix.Tasks.Polymarket.Ingest do
  @moduledoc """
  Ingest trades from Polymarket API or blockchain subgraph.

  Supports multiple ingestion strategies for casting a wide net across all markets.

  ## Usage

      # Ingest recent trades across all markets (default)
      mix polymarket.ingest
      mix polymarket.ingest --recent --limit 5000

      # Ingest from specific market
      mix polymarket.ingest --market 0xabc123...

      # Ingest from all markets in a category
      mix polymarket.ingest --category crypto
      mix polymarket.ingest --category sports --limit 1000

      # Ingest from all currently active markets
      mix polymarket.ingest --all-active

      # Continuous mode (run until stopped)
      mix polymarket.ingest --continuous --interval 300

      # HISTORICAL: Ingest from blockchain subgraph (bypasses API geo-blocking)
      mix polymarket.ingest --subgraph --from 2025-10-01 --to 2025-10-15
      mix polymarket.ingest --subgraph --days 30

      # TARGETED: Ingest trades for specific market (e.g., reference cases)
      mix polymarket.ingest --subgraph --condition 0x123... --from 2025-10-01
      mix polymarket.ingest --subgraph --reference-cases

      # SCAN MODE: Analyze trades by market without ingesting (Phase 1 discovery)
      mix polymarket.ingest --subgraph --from 2025-10-01 --to 2025-10-15 --scan
      mix polymarket.ingest --subgraph --days 7 --scan --top 20

  ## Options

      --recent         Ingest recent trades across all markets (default)
      --market ID      Ingest from specific market condition ID
      --category CAT   Ingest from all markets in category
                       (politics, corporate, legal, crypto, sports, entertainment, science, other)
      --all-active     Ingest from all currently active markets
      --limit N        Maximum trades to ingest (default: 2000)
      --continuous     Run continuously until stopped
      --interval SEC   Seconds between continuous runs (default: 300)
      --verbose        Show detailed output

      --subgraph       Use blockchain subgraph for historical data (bypasses geo-blocking)
      --from DATE      Start date for subgraph mode (YYYY-MM-DD)
      --to DATE        End date for subgraph mode (YYYY-MM-DD, default: today)
      --days N         Alternative to --from/--to: ingest last N days
      --condition ID   Ingest trades for specific condition_id (use with --subgraph)
      --reference-cases Ingest trades for all reference cases with condition_ids
      --scan           Scan mode: analyze trades grouped by market (no ingestion)
      --top N          Show top N markets by volume in scan mode (default: 10)

  ## Categories

  Valid categories: politics, corporate, legal, crypto, sports, entertainment, science, other

  ## Examples

      $ mix polymarket.ingest --category crypto --limit 500

      ═══════════════════════════════════════════════════════════════
      POLYMARKET TRADE INGESTION
      ═══════════════════════════════════════════════════════════════

      Mode: Category (crypto)
      Limit: 500 trades per market

      Ingesting from 23 markets...

      ✅ Ingestion complete!
         Markets processed: 23
         Trades inserted: 1,245
         Trades updated: 89
         Errors: 0

      $ mix polymarket.ingest --subgraph --from 2025-10-08 --to 2025-10-12

      ═══════════════════════════════════════════════════════════════
      POLYMARKET SUBGRAPH INGESTION (Historical)
      ═══════════════════════════════════════════════════════════════

      Source: Blockchain subgraph (The Graph/Goldsky)
      Date range: 2025-10-08 to 2025-10-12

      Fetching trades from subgraph...
      Building token ID mapping (366 markets)...

      ✅ Historical ingestion complete!
         Trades fetched: 15,234
         Trades mapped: 12,456 (81.8%)
         Trades inserted: 11,234
         Unmapped (unknown markets): 2,778

      $ mix polymarket.ingest --subgraph --from 2025-10-08 --to 2025-10-12 --scan --top 5

      ═══════════════════════════════════════════════════════════════
      POLYMARKET SUBGRAPH SCAN (Date-Range Analysis)
      ═══════════════════════════════════════════════════════════════

      Analyzing trades by market...

      ═══════════════════════════════════════════════════════════════
      SCAN RESULTS SUMMARY
      ═══════════════════════════════════════════════════════════════

         Total trades: 15,234
         Total volume: $2,456,789.00
         Unique markets: 156
         Mapped to known condition_ids: 134

      ─────────────────────────────────────────────────────────────────
      TOP 5 MARKETS BY VOLUME
      ─────────────────────────────────────────────────────────────────

      1. 0x14a3dfeba8b22a32fe...
         Volume: $456,123.45 | Trades: 2,345
         Wallets: 189 | Whale trades (>$1K): 45
         Period: 2025-10-08 09:15 → 2025-10-12 23:45
  """

  use Mix.Task
  require Logger
  import Ecto.Query
  alias VolfefeMachine.Polymarket
  alias VolfefeMachine.Polymarket.{SubgraphClient, TokenMapping, InsiderReferenceCase}
  alias VolfefeMachine.Repo

  @shortdoc "Ingest trades from Polymarket"

  @valid_categories ~w(politics corporate legal crypto sports entertainment science other)

  @impl Mix.Task
  def run(args) do
    Mix.Task.run("app.start")

    {opts, _, _} = OptionParser.parse(args,
      switches: [
        recent: :boolean,
        market: :string,
        category: :string,
        all_active: :boolean,
        limit: :integer,
        continuous: :boolean,
        interval: :integer,
        verbose: :boolean,
        # Subgraph options
        subgraph: :boolean,
        from: :string,
        to: :string,
        days: :integer,
        condition: :string,
        reference_cases: :boolean,
        scan: :boolean,
        top: :integer
      ],
      aliases: [m: :market, c: :category, l: :limit, v: :verbose]
    )

    cond do
      opts[:subgraph] && opts[:scan] ->
        print_scan_header()
        scan_from_subgraph(opts)
        print_scan_footer()

      opts[:subgraph] && opts[:reference_cases] ->
        print_subgraph_header()
        ingest_reference_cases_from_subgraph(opts)
        print_subgraph_footer()

      opts[:subgraph] && opts[:condition] ->
        print_subgraph_header()
        ingest_condition_from_subgraph(opts[:condition], opts)
        print_subgraph_footer()

      opts[:subgraph] ->
        print_subgraph_header()
        ingest_from_subgraph(opts)
        print_subgraph_footer()

      opts[:continuous] ->
        print_header()
        run_continuous(opts)

      opts[:market] ->
        print_header()
        ingest_market(opts[:market], opts)
        print_footer()

      opts[:category] ->
        print_header()
        ingest_category(opts[:category], opts)
        print_footer()

      opts[:all_active] ->
        print_header()
        ingest_all_active(opts)
        print_footer()

      true ->
        print_header()
        # Default: recent trades
        ingest_recent(opts)
        print_footer()
    end
  end

  defp ingest_recent(opts) do
    limit = opts[:limit] || 2000

    Mix.shell().info("Mode: Recent trades across all markets")
    Mix.shell().info("Limit: #{format_number(limit)} trades")
    Mix.shell().info("")

    case Polymarket.ingest_recent_trades(limit: limit) do
      {:ok, stats} ->
        print_success(stats, 1)

      {:error, reason} ->
        Mix.shell().error("❌ Ingestion failed: #{inspect(reason)}")
    end
  end

  defp ingest_market(condition_id, opts) do
    limit = opts[:limit] || 10_000

    Mix.shell().info("Mode: Single market")
    Mix.shell().info("Market: #{truncate(condition_id, 20)}...")
    Mix.shell().info("Limit: #{format_number(limit)} trades")
    Mix.shell().info("")

    case Polymarket.ingest_market_trades(condition_id, max_trades: limit) do
      {:ok, stats} ->
        print_success(stats, 1)

      {:error, reason} ->
        Mix.shell().error("❌ Ingestion failed: #{inspect(reason)}")
    end
  end

  defp ingest_category(category, opts) do
    unless category in @valid_categories do
      Mix.shell().error("❌ Invalid category: #{category}")
      Mix.shell().info("")
      Mix.shell().info("Valid categories: #{Enum.join(@valid_categories, ", ")}")
      exit({:shutdown, 1})
    end

    limit = opts[:limit] || 500
    category_atom = String.to_atom(category)

    Mix.shell().info("Mode: Category (#{category})")
    Mix.shell().info("Limit: #{format_number(limit)} trades per market")
    Mix.shell().info("")

    # Get all active markets in this category
    markets = Polymarket.list_markets(category: category_atom, is_active: true, limit: 500)

    if length(markets) == 0 do
      Mix.shell().info("⚠️  No active markets found in category: #{category}")
      Mix.shell().info("")
      Mix.shell().info("Try syncing markets first: mix polymarket.sync")
      {:ok, %{inserted: 0, updated: 0, errors: 0}}
    else
      Mix.shell().info("Found #{length(markets)} active markets in #{category}")
      Mix.shell().info("")

      if opts[:verbose] do
        Mix.shell().info("Markets:")
        Enum.take(markets, 5) |> Enum.each(fn m ->
          Mix.shell().info("  - #{truncate(m.question, 50)}")
        end)
        if length(markets) > 5, do: Mix.shell().info("  ... and #{length(markets) - 5} more")
        Mix.shell().info("")
      end

      results = Enum.map(markets, fn market ->
        case Polymarket.ingest_market_trades(market.condition_id, max_trades: limit) do
          {:ok, stats} -> {:ok, stats}
          {:error, _} = err -> err
        end
      end)

      # Aggregate stats
      aggregate_stats = aggregate_results(results)
      print_success(aggregate_stats, length(markets))
    end
  end

  defp ingest_all_active(opts) do
    limit = opts[:limit] || 200

    Mix.shell().info("Mode: All active markets")
    Mix.shell().info("Limit: #{format_number(limit)} trades per market")
    Mix.shell().info("")

    # Get all active markets
    markets = Polymarket.list_markets(is_active: true, limit: 1000)

    if length(markets) == 0 do
      Mix.shell().info("⚠️  No active markets found")
      Mix.shell().info("")
      Mix.shell().info("Try syncing markets first: mix polymarket.sync")
      {:ok, %{inserted: 0, updated: 0, errors: 0}}
    else
      Mix.shell().info("Found #{length(markets)} active markets")
      Mix.shell().info("")

      # Group by category for progress
      by_category = Enum.group_by(markets, & &1.category)

      if opts[:verbose] do
        Mix.shell().info("By category:")
        Enum.each(by_category, fn {cat, ms} ->
          Mix.shell().info("  #{cat || "other"}: #{length(ms)} markets")
        end)
        Mix.shell().info("")
      end

      results = Enum.with_index(markets) |> Enum.map(fn {market, idx} ->
        if rem(idx + 1, 10) == 0 do
          Mix.shell().info("  Progress: #{idx + 1}/#{length(markets)} markets...")
        end

        case Polymarket.ingest_market_trades(market.condition_id, max_trades: limit) do
          {:ok, stats} -> {:ok, stats}
          {:error, _} = err -> err
        end
      end)

      Mix.shell().info("")
      aggregate_stats = aggregate_results(results)
      print_success(aggregate_stats, length(markets))
    end
  end

  defp run_continuous(opts) do
    interval = (opts[:interval] || 300) * 1000  # Convert to ms
    limit = opts[:limit] || 2000

    Mix.shell().info("Mode: Continuous ingestion")
    Mix.shell().info("Interval: #{div(interval, 1000)} seconds")
    Mix.shell().info("Limit: #{format_number(limit)} trades per run")
    Mix.shell().info("")
    Mix.shell().info("Press Ctrl+C to stop")
    Mix.shell().info("")

    continuous_loop(limit, interval, 1)
  end

  defp continuous_loop(limit, interval, iteration) do
    Mix.shell().info("─── Run ##{iteration} @ #{format_time(DateTime.utc_now())} ───")

    case Polymarket.ingest_recent_trades(limit: limit) do
      {:ok, stats} ->
        Mix.shell().info("  Inserted: #{stats.inserted}, Updated: #{stats.updated}, Errors: #{stats.errors}")

      {:error, reason} ->
        Mix.shell().error("  Error: #{inspect(reason)}")
    end

    Mix.shell().info("  Next run in #{div(interval, 1000)} seconds...")
    Mix.shell().info("")

    Process.sleep(interval)
    continuous_loop(limit, interval, iteration + 1)
  end

  defp aggregate_results(results) do
    Enum.reduce(results, %{inserted: 0, updated: 0, errors: 0, market_errors: 0}, fn
      {:ok, stats}, acc ->
        %{
          inserted: acc.inserted + (stats[:inserted] || 0),
          updated: acc.updated + (stats[:updated] || 0),
          errors: acc.errors + (stats[:errors] || 0),
          market_errors: acc.market_errors
        }

      {:error, _}, acc ->
        %{acc | market_errors: acc.market_errors + 1}
    end)
  end

  defp print_header do
    Mix.shell().info("")
    Mix.shell().info(String.duplicate("═", 65))
    Mix.shell().info("POLYMARKET TRADE INGESTION")
    Mix.shell().info(String.duplicate("═", 65))
    Mix.shell().info("")
  end

  defp print_footer do
    Mix.shell().info(String.duplicate("─", 65))
    Mix.shell().info("Check coverage: mix polymarket.coverage")
    Mix.shell().info("")
  end

  defp print_success(stats, market_count) do
    Mix.shell().info("✅ Ingestion complete!")
    Mix.shell().info("   Markets processed: #{format_number(market_count)}")
    Mix.shell().info("   Trades inserted: #{format_number(stats.inserted)}")
    Mix.shell().info("   Trades updated: #{format_number(stats.updated)}")
    Mix.shell().info("   Trade errors: #{stats.errors}")

    if Map.get(stats, :market_errors, 0) > 0 do
      Mix.shell().info("   Market errors: #{stats.market_errors}")
    end

    Mix.shell().info("")
  end

  defp format_number(n) when is_integer(n) do
    n
    |> Integer.to_string()
    |> String.reverse()
    |> String.replace(~r/(\d{3})(?=\d)/, "\\1,")
    |> String.reverse()
  end
  defp format_number(n), do: "#{n}"

  defp format_time(%DateTime{} = dt) do
    Calendar.strftime(dt, "%H:%M:%S")
  end

  defp truncate(nil, _), do: ""
  defp truncate(str, max_length) when is_binary(str) do
    if String.length(str) > max_length do
      String.slice(str, 0, max_length)
    else
      str
    end
  end

  # ============================================
  # Subgraph Ingestion (Historical)
  # ============================================

  # Ingest trades for all reference cases with condition_ids
  defp ingest_reference_cases_from_subgraph(opts) do
    Mix.shell().info("Mode: Reference Cases (Ground Truth Data)")
    Mix.shell().info("Source: Blockchain subgraph (The Graph/Goldsky)")
    Mix.shell().info("")

    # Get all Polymarket reference cases that have condition_ids
    ref_cases = from(r in InsiderReferenceCase,
      where: r.platform == "polymarket" and not is_nil(r.condition_id),
      order_by: r.event_date
    ) |> Repo.all()

    if length(ref_cases) == 0 do
      Mix.shell().info("⚠️  No reference cases have condition_ids yet!")
      Mix.shell().info("")
      Mix.shell().info("Run this first to populate condition_ids:")
      Mix.shell().info("  mix polymarket.references --lookup")
      Mix.shell().info("")
    else
      Mix.shell().info("Found #{length(ref_cases)} reference cases with condition_ids:")
      Mix.shell().info("")

      Enum.each(ref_cases, fn rc ->
        event_date = if rc.event_date, do: Date.to_string(rc.event_date), else: "N/A"
        Mix.shell().info("  • #{rc.case_name} (#{event_date})")
        Mix.shell().info("    condition_id: #{truncate(rc.condition_id, 30)}...")
      end)

      Mix.shell().info("")
      Mix.shell().info(String.duplicate("─", 65))
      Mix.shell().info("")

      # Process each reference case
      results = Enum.map(ref_cases, fn rc ->
        ingest_reference_case(rc, opts)
      end)

      # Summary
      {total_fetched, total_inserted, total_updated, total_errors} =
        Enum.reduce(results, {0, 0, 0, 0}, fn
          {:ok, stats}, {f, i, u, e} ->
            {f + stats.fetched, i + stats.inserted, u + stats.updated, e + stats.errors}
          {:error, _}, acc ->
            acc
        end)

      Mix.shell().info("")
      Mix.shell().info(String.duplicate("═", 65))
      Mix.shell().info("REFERENCE CASE INGESTION SUMMARY")
      Mix.shell().info(String.duplicate("═", 65))
      Mix.shell().info("   Cases processed: #{length(ref_cases)}")
      Mix.shell().info("   Total trades fetched: #{format_number(total_fetched)}")
      Mix.shell().info("   Trades inserted: #{format_number(total_inserted)}")
      Mix.shell().info("   Trades updated: #{format_number(total_updated)}")
      Mix.shell().info("   Errors: #{total_errors}")
    end
  end

  defp ingest_reference_case(ref_case, opts) do
    Mix.shell().info("🔍 #{ref_case.case_name}")

    # Determine date range: 7 days before event to 3 days after
    {from_date, to_date} = case ref_case.event_date do
      nil ->
        # Fall back to opts or default
        parse_date_range(opts)

      event_date ->
        # 7 days before to 3 days after the event
        from = Date.add(event_date, -7)
        to = Date.add(event_date, 3)
        {from, to}
    end

    Mix.shell().info("   Date range: #{from_date} to #{to_date}")

    result = ingest_condition_from_subgraph(ref_case.condition_id, Keyword.merge(opts, [
      from: Date.to_iso8601(from_date),
      to: Date.to_iso8601(to_date),
      reference_case_id: ref_case.id
    ]))

    # Update reference case with ingestion info
    case result do
      {:ok, stats} ->
        InsiderReferenceCase.changeset(ref_case, %{
          trades_ingested_at: DateTime.utc_now(),
          trades_count: stats.fetched
        })
        |> Repo.update()

        Mix.shell().info("   ✅ #{stats.fetched} trades fetched, #{stats.inserted} inserted")
        {:ok, stats}

      {:error, reason} ->
        Mix.shell().info("   ❌ Error: #{reason}")
        {:error, reason}
    end
  end

  # Ingest trades for a specific condition_id
  defp ingest_condition_from_subgraph(condition_id, opts) do
    {from_date, to_date} = parse_date_range(opts)
    limit = opts[:limit] || 50_000
    verbose = opts[:verbose] || false

    unless opts[:reference_cases] do
      Mix.shell().info("Mode: Single Condition (Targeted)")
      Mix.shell().info("Source: Blockchain subgraph (The Graph/Goldsky)")
      Mix.shell().info("Condition ID: #{truncate(condition_id, 40)}...")
      Mix.shell().info("Date range: #{from_date} to #{to_date}")
      Mix.shell().info("Max trades: #{format_number(limit)}")
      Mix.shell().info("")
    end

    # Check subgraph health
    case SubgraphClient.subgraph_healthy?(:orderbook) do
      {:ok, true} -> :ok
      {:ok, false} -> Mix.shell().info("⚠️  Subgraph may be behind")
      {:error, _} -> :ok
    end

    # Get token IDs for this condition_id
    # First try to find in our local DB
    alias VolfefeMachine.Polymarket.Market
    market = Repo.get_by(Market, condition_id: condition_id)

    token_ids = case market do
      nil ->
        # No local market, need to find token IDs from subgraph
        Mix.shell().info("   Looking up token IDs from subgraph...")
        case SubgraphClient.get_token_ids_for_condition(condition_id, max_events: 1000) do
          {:ok, ids} when ids != [] ->
            Mix.shell().info("   Found #{length(ids)} token IDs")
            ids
          _ ->
            Mix.shell().info("   ⚠️  Could not determine token IDs")
            []
        end

      market ->
        case TokenMapping.extract_token_ids(market.meta) do
          {:ok, ids} ->
            Mix.shell().info("   Found #{length(ids)} token IDs from local DB")
            ids
          _ ->
            []
        end
    end

    if token_ids == [] do
      Mix.shell().error("   ❌ No token IDs found for this market")
      {:error, "No token IDs found"}
    else
      # Fetch trades from subgraph for these specific token IDs
      from_ts = date_to_unix(from_date)
      to_ts = date_to_unix(to_date) + 86399

      # Build simple mapping for this market
      market_id = if market, do: market.id, else: find_or_create_market_id(condition_id)

      local_mapping = Enum.with_index(token_ids)
      |> Enum.reduce(%{}, fn {token_id, idx}, acc ->
        Map.put(acc, token_id, %{
          market_id: market_id,
          condition_id: condition_id,
          outcome_index: idx
        })
      end)

      # Fetch trades for these token IDs
      all_events = Enum.flat_map(token_ids, fn token_id ->
        case SubgraphClient.get_all_order_filled_events(
               from_timestamp: from_ts,
               to_timestamp: to_ts,
               max_events: limit,
               token_id: token_id
             ) do
          {:ok, events} -> events
          {:error, _} -> []
        end
      end)

      # Deduplicate by event ID
      events = all_events
      |> Enum.uniq_by(fn e -> e["id"] end)

      if verbose do
        Mix.shell().info("   Fetched #{length(events)} unique trades")
      end

      # Insert trades
      {inserted, updated, errors} = insert_subgraph_trades(events, {local_mapping, %{}}, verbose)

      {:ok, %{
        fetched: length(events),
        inserted: inserted,
        updated: updated,
        errors: errors
      }}
    end
  end

  defp ingest_from_subgraph(opts) do
    {from_date, to_date} = parse_date_range(opts)
    limit = opts[:limit] || 100_000
    verbose = opts[:verbose] || false

    Mix.shell().info("Source: Blockchain subgraph (The Graph/Goldsky)")
    Mix.shell().info("Date range: #{from_date} to #{to_date}")
    Mix.shell().info("Max trades: #{format_number(limit)}")
    Mix.shell().info("")

    # Check subgraph health
    case SubgraphClient.subgraph_healthy?(:orderbook) do
      {:ok, true} ->
        Mix.shell().info("✅ Subgraph is healthy and synced")

      {:ok, false} ->
        Mix.shell().info("⚠️  Subgraph may be behind - results might be incomplete")

      {:error, reason} ->
        Mix.shell().error("⚠️  Could not check subgraph health: #{reason}")
    end

    Mix.shell().info("")

    # Build token mapping - combine local DB and subgraph
    Mix.shell().info("Building token ID mapping...")

    # First, get local mapping from our database
    {:ok, local_mapping} = TokenMapping.build_mapping(include_inactive: true)
    mapping_stats = TokenMapping.stats()
    Mix.shell().info("  Local DB: #{mapping_stats.unique_markets} markets with #{mapping_stats.total_tokens} token IDs")

    # Then, get subgraph mapping for tokens not in our DB
    Mix.shell().info("  Fetching subgraph token mappings...")
    {:ok, subgraph_mapping} = SubgraphClient.build_subgraph_token_mapping(
      max_mappings: 50_000,
      progress_callback: fn %{fetched: f} ->
        if rem(f, 10_000) == 0 do
          Mix.shell().info("    Fetched #{f} subgraph mappings...")
        end
      end
    )
    Mix.shell().info("  Subgraph: #{map_size(subgraph_mapping)} token mappings")

    # Combine mappings (local takes precedence)
    combined_mapping = {local_mapping, subgraph_mapping}
    Mix.shell().info("")

    # Fetch trades from subgraph
    Mix.shell().info("Fetching trades from subgraph...")

    progress_callback = fn %{fetched: fetched, batch: _batch} ->
      if rem(fetched, 5000) == 0 do
        Mix.shell().info("  Progress: #{format_number(fetched)} trades fetched...")
      end
    end

    from_ts = date_to_unix(from_date)
    to_ts = date_to_unix(to_date) + 86399  # End of day

    case SubgraphClient.get_all_order_filled_events(
           from_timestamp: from_ts,
           to_timestamp: to_ts,
           max_events: limit,
           progress_callback: progress_callback
         ) do
      {:ok, events} ->
        Mix.shell().info("  ✅ Fetched #{format_number(length(events))} trades")
        Mix.shell().info("")

        # Process and insert trades
        process_subgraph_events(events, combined_mapping, verbose)

      {:error, reason} ->
        Mix.shell().error("❌ Failed to fetch from subgraph: #{reason}")
    end
  end

  # ============================================
  # Scan Mode (Date-Range Analysis)
  # ============================================

  defp scan_from_subgraph(opts) do
    {from_date, to_date} = parse_date_range(opts)
    limit = opts[:limit] || 100_000
    top_n = opts[:top] || 10

    Mix.shell().info("Source: Blockchain subgraph (The Graph/Goldsky)")
    Mix.shell().info("Date range: #{from_date} to #{to_date}")
    Mix.shell().info("Max trades: #{format_number(limit)}")
    Mix.shell().info("")

    # Check subgraph health
    case SubgraphClient.subgraph_healthy?(:orderbook) do
      {:ok, true} ->
        Mix.shell().info("✅ Subgraph is healthy and synced")

      {:ok, false} ->
        Mix.shell().info("⚠️  Subgraph may be behind - results might be incomplete")

      {:error, reason} ->
        Mix.shell().error("⚠️  Could not check subgraph health: #{reason}")
    end

    Mix.shell().info("")

    # Build token mapping
    Mix.shell().info("Building token ID mapping...")

    {:ok, local_mapping} = TokenMapping.build_mapping(include_inactive: true)
    mapping_stats = TokenMapping.stats()
    Mix.shell().info("  Local DB: #{mapping_stats.unique_markets} markets with #{mapping_stats.total_tokens} token IDs")

    Mix.shell().info("  Fetching subgraph token mappings...")
    {:ok, subgraph_mapping} = SubgraphClient.build_subgraph_token_mapping(
      max_mappings: 50_000,
      progress_callback: fn %{fetched: f} ->
        if rem(f, 10_000) == 0 do
          Mix.shell().info("    Fetched #{f} subgraph mappings...")
        end
      end
    )
    Mix.shell().info("  Subgraph: #{map_size(subgraph_mapping)} token mappings")

    combined_mapping = {local_mapping, subgraph_mapping}
    Mix.shell().info("")

    # Fetch trades from subgraph
    Mix.shell().info("Fetching trades from subgraph...")

    progress_callback = fn %{fetched: fetched, batch: _batch} ->
      if rem(fetched, 5000) == 0 do
        Mix.shell().info("  Progress: #{format_number(fetched)} trades fetched...")
      end
    end

    from_ts = date_to_unix(from_date)
    to_ts = date_to_unix(to_date) + 86399

    case SubgraphClient.get_all_order_filled_events(
           from_timestamp: from_ts,
           to_timestamp: to_ts,
           max_events: limit,
           progress_callback: progress_callback
         ) do
      {:ok, events} ->
        Mix.shell().info("  ✅ Fetched #{format_number(length(events))} trades")
        Mix.shell().info("")

        # Analyze and display grouped market stats
        analyze_scan_results(events, combined_mapping, top_n)

      {:error, reason} ->
        Mix.shell().error("❌ Failed to fetch from subgraph: #{reason}")
    end
  end

  defp analyze_scan_results(events, combined_mapping, top_n) do
    {local_mapping, subgraph_mapping} = combined_mapping

    Mix.shell().info("Analyzing trades by market...")
    Mix.shell().info("")

    # Group events by token_id (market)
    grouped = Enum.group_by(events, fn event ->
      token_id = event["makerAssetId"]
      if token_id == "0", do: event["takerAssetId"], else: token_id
    end)

    # Calculate stats for each market
    market_stats = Enum.map(grouped, fn {token_id, trades} ->
      # Get condition_id from mapping
      condition_id = case TokenMapping.lookup(local_mapping, token_id) do
        {:ok, %{condition_id: cid}} -> cid
        :not_found ->
          case Map.get(subgraph_mapping, token_id) do
            %{condition_id: cid} -> cid
            _ -> nil
          end
      end

      # Calculate volume (sum of USDC amounts)
      total_volume = Enum.reduce(trades, Decimal.new(0), fn trade, acc ->
        # Calculate USDC value
        maker_amount = parse_amount(trade["makerAmountFilled"])
        taker_amount = parse_amount(trade["takerAmountFilled"])
        # The smaller of the two is typically the USDC side
        usdc = Decimal.min(maker_amount, taker_amount)
        Decimal.add(acc, usdc)
      end)

      # Get unique wallets
      wallets = Enum.flat_map(trades, fn t -> [t["maker"], t["taker"]] end)
                |> Enum.uniq()
                |> length()

      # Count large trades (>$1000)
      whale_trades = Enum.count(trades, fn trade ->
        maker_amount = parse_amount(trade["makerAmountFilled"])
        taker_amount = parse_amount(trade["takerAmountFilled"])
        usdc = Decimal.min(maker_amount, taker_amount)
        Decimal.compare(usdc, Decimal.new(1000)) == :gt
      end)

      # Get timestamps for date range
      timestamps = Enum.map(trades, fn t ->
        t["timestamp"] |> String.to_integer()
      end)
      first_ts = Enum.min(timestamps)
      last_ts = Enum.max(timestamps)

      %{
        token_id: token_id,
        condition_id: condition_id,
        trade_count: length(trades),
        total_volume: total_volume,
        unique_wallets: wallets,
        whale_trades: whale_trades,
        first_trade: DateTime.from_unix!(first_ts),
        last_trade: DateTime.from_unix!(last_ts)
      }
    end)

    # Sort by volume (highest first)
    sorted = Enum.sort_by(market_stats, & &1.total_volume, {:desc, Decimal})

    # Stats summary
    total_markets = length(sorted)
    mapped_markets = Enum.count(sorted, & &1.condition_id != nil)
    total_volume = Enum.reduce(sorted, Decimal.new(0), fn m, acc ->
      Decimal.add(acc, m.total_volume)
    end)
    total_trades = Enum.reduce(sorted, 0, fn m, acc -> acc + m.trade_count end)

    Mix.shell().info(String.duplicate("═", 65))
    Mix.shell().info("SCAN RESULTS SUMMARY")
    Mix.shell().info(String.duplicate("═", 65))
    Mix.shell().info("")
    Mix.shell().info("   Total trades: #{format_number(total_trades)}")
    Mix.shell().info("   Total volume: $#{format_decimal(total_volume)}")
    Mix.shell().info("   Unique markets: #{format_number(total_markets)}")
    Mix.shell().info("   Mapped to known condition_ids: #{format_number(mapped_markets)}")
    Mix.shell().info("")

    # Show top N markets
    top_markets = Enum.take(sorted, top_n)

    Mix.shell().info(String.duplicate("─", 65))
    Mix.shell().info("TOP #{top_n} MARKETS BY VOLUME")
    Mix.shell().info(String.duplicate("─", 65))
    Mix.shell().info("")

    Enum.with_index(top_markets, 1) |> Enum.each(fn {market, rank} ->
      cond_display = if market.condition_id do
        truncate(market.condition_id, 20) <> "..."
      else
        "(unmapped token: #{truncate(market.token_id, 15)}...)"
      end

      Mix.shell().info("#{rank}. #{cond_display}")
      Mix.shell().info("   Volume: $#{format_decimal(market.total_volume)} | Trades: #{format_number(market.trade_count)}")
      Mix.shell().info("   Wallets: #{market.unique_wallets} | Whale trades (>$1K): #{market.whale_trades}")
      Mix.shell().info("   Period: #{format_datetime(market.first_trade)} → #{format_datetime(market.last_trade)}")
      Mix.shell().info("")
    end)

    # Show markets with highest whale activity (potential insider signal)
    high_whale = sorted
    |> Enum.filter(& &1.whale_trades > 0)
    |> Enum.sort_by(& &1.whale_trades, :desc)
    |> Enum.take(5)

    if length(high_whale) > 0 do
      Mix.shell().info(String.duplicate("─", 65))
      Mix.shell().info("TOP 5 MARKETS BY WHALE ACTIVITY (>$1K trades)")
      Mix.shell().info(String.duplicate("─", 65))
      Mix.shell().info("")

      Enum.with_index(high_whale, 1) |> Enum.each(fn {market, rank} ->
        cond_display = if market.condition_id do
          truncate(market.condition_id, 30) <> "..."
        else
          "(unmapped)"
        end

        Mix.shell().info("#{rank}. #{cond_display}")
        Mix.shell().info("   Whale trades: #{market.whale_trades} | Total: $#{format_decimal(market.total_volume)}")
        Mix.shell().info("")
      end)
    end
  end

  defp format_decimal(%Decimal{} = d) do
    d
    |> Decimal.round(2)
    |> Decimal.to_string()
    |> String.replace(~r/(\d)(?=(\d{3})+(?!\d))/, "\\1,")
  end
  defp format_decimal(n), do: "#{n}"

  defp format_datetime(%DateTime{} = dt) do
    Calendar.strftime(dt, "%Y-%m-%d %H:%M")
  end

  defp print_scan_header do
    Mix.shell().info("")
    Mix.shell().info(String.duplicate("═", 65))
    Mix.shell().info("POLYMARKET SUBGRAPH SCAN (Date-Range Analysis)")
    Mix.shell().info(String.duplicate("═", 65))
    Mix.shell().info("")
  end

  defp print_scan_footer do
    Mix.shell().info(String.duplicate("─", 65))
    Mix.shell().info("Use --top N to show more markets")
    Mix.shell().info("Use without --scan to ingest trades")
    Mix.shell().info("")
  end

  defp process_subgraph_events(events, combined_mapping, verbose) do
    {local_mapping, subgraph_mapping} = combined_mapping
    Mix.shell().info("Processing trades...")

    # Group events by whether we can map them
    {mapped, unmapped} =
      Enum.split_with(events, fn event ->
        token_id = event["makerAssetId"]
        # Token ID "0" is USDC (collateral), check the other side
        token_id = if token_id == "0", do: event["takerAssetId"], else: token_id
        # Check both local and subgraph mapping
        Map.has_key?(local_mapping, token_id) or Map.has_key?(subgraph_mapping, token_id)
      end)

    # Count local vs subgraph mappings
    {local_count, subgraph_count} = Enum.reduce(mapped, {0, 0}, fn event, {lc, sc} ->
      token_id = event["makerAssetId"]
      token_id = if token_id == "0", do: event["takerAssetId"], else: token_id
      if Map.has_key?(local_mapping, token_id), do: {lc + 1, sc}, else: {lc, sc + 1}
    end)

    Mix.shell().info("  Mapped to known markets: #{format_number(length(mapped))} (#{percentage(length(mapped), length(events))}%)")
    Mix.shell().info("    - Via local DB: #{format_number(local_count)}")
    Mix.shell().info("    - Via subgraph: #{format_number(subgraph_count)}")
    Mix.shell().info("  Unknown markets: #{format_number(length(unmapped))}")
    Mix.shell().info("")

    # Convert and insert mapped trades
    {inserted, updated, errors} = insert_subgraph_trades(mapped, combined_mapping, verbose)

    Mix.shell().info("")
    Mix.shell().info("✅ Historical ingestion complete!")
    Mix.shell().info("   Trades fetched: #{format_number(length(events))}")
    Mix.shell().info("   Trades mapped: #{format_number(length(mapped))} (#{percentage(length(mapped), length(events))}%)")
    Mix.shell().info("   Trades inserted: #{format_number(inserted)}")
    Mix.shell().info("   Trades updated: #{format_number(updated)}")
    Mix.shell().info("   Errors: #{errors}")
    Mix.shell().info("   Unmapped (unknown markets): #{format_number(length(unmapped))}")
  end

  defp insert_subgraph_trades(events, mapping, verbose) do
    alias VolfefeMachine.Polymarket.Trade

    # Process in batches
    batch_size = 500
    total = length(events)

    events
    |> Enum.with_index()
    |> Enum.chunk_every(batch_size)
    |> Enum.reduce({0, 0, 0}, fn batch, {total_inserted, total_updated, total_errors} ->
      batch_results = Enum.map(batch, fn {event, idx} ->
        if verbose && rem(idx + 1, 1000) == 0 do
          Mix.shell().info("  Inserting: #{idx + 1}/#{total}...")
        end

        insert_single_trade(event, mapping)
      end)

      inserted = Enum.count(batch_results, &(&1 == :inserted))
      updated = Enum.count(batch_results, &(&1 == :updated))
      errors = Enum.count(batch_results, &(&1 == :error))

      {total_inserted + inserted, total_updated + updated, total_errors + errors}
    end)
  end

  defp insert_single_trade(event, combined_mapping) do
    alias VolfefeMachine.Polymarket.{Trade, Wallet, Market}
    {local_mapping, subgraph_mapping} = combined_mapping

    # Determine which token ID to use for mapping
    maker_asset = event["makerAssetId"]
    taker_asset = event["takerAssetId"]

    # If maker is selling tokens (makerAssetId != 0), that's the market token
    # If taker is receiving tokens (takerAssetId != 0), that's the market token
    {token_id, side, wallet_address} = cond do
      maker_asset != "0" ->
        # Maker is selling market tokens -> this is a SELL
        {maker_asset, "SELL", event["maker"]}

      taker_asset != "0" ->
        # Taker is receiving market tokens -> this is a BUY
        {taker_asset, "BUY", event["taker"]}

      true ->
        # Shouldn't happen, but default to maker
        {maker_asset, "SELL", event["maker"]}
    end

    # Try local mapping first, then subgraph
    mapping_result = case TokenMapping.lookup(local_mapping, token_id) do
      {:ok, info} ->
        {:ok, info}

      :not_found ->
        # Try subgraph mapping
        case Map.get(subgraph_mapping, token_id) do
          nil ->
            :not_found

          %{condition_id: cond_id, outcome_index: out_idx} ->
            # Find or create market from condition_id
            market_id = find_or_create_market_id(cond_id)
            {:ok, %{market_id: market_id, condition_id: cond_id, outcome_index: out_idx || 0}}
        end
    end

    case mapping_result do
      {:ok, %{market_id: market_id, condition_id: condition_id, outcome_index: outcome_index}} ->
        timestamp = event["timestamp"]
        |> String.to_integer()
        |> DateTime.from_unix!()

        # Calculate amounts (in USDC, divide by 10^6)
        maker_amount = parse_amount(event["makerAmountFilled"])
        taker_amount = parse_amount(event["takerAmountFilled"])

        # For a BUY: you pay taker_amount USDC to get maker_amount tokens
        # For a SELL: you give maker_amount tokens to get taker_amount USDC
        {size, usdc_size, price} = case side do
          "BUY" ->
            size = maker_amount
            usdc = taker_amount
            price = if size > 0, do: Decimal.div(usdc, size), else: Decimal.new(0)
            {size, usdc, price}

          "SELL" ->
            size = maker_amount
            usdc = taker_amount
            price = if size > 0, do: Decimal.div(usdc, size), else: Decimal.new(0)
            {size, usdc, price}
        end

        # Create a unique transaction hash from the event ID
        tx_hash = event["id"]

        outcome = if outcome_index == 0, do: "Yes", else: "No"

        attrs = %{
          transaction_hash: tx_hash,
          wallet_address: wallet_address,
          condition_id: condition_id,
          market_id: market_id,
          side: side,
          outcome: outcome,
          outcome_index: outcome_index,
          size: size,
          price: Decimal.round(price, 4),
          usdc_size: usdc_size,
          trade_timestamp: timestamp,
          meta: %{
            source: "subgraph",
            maker: event["maker"],
            taker: event["taker"],
            makerAssetId: event["makerAssetId"],
            takerAssetId: event["takerAssetId"]
          }
        }

        case Repo.get_by(Trade, transaction_hash: tx_hash) do
          nil ->
            # Ensure wallet exists
            ensure_wallet(wallet_address)

            case %Trade{}
                 |> Trade.changeset(attrs)
                 |> Repo.insert() do
              {:ok, _} -> :inserted
              {:error, _} -> :error
            end

          _existing ->
            :updated  # Already exists
        end

      :not_found ->
        :error
    end
  rescue
    _ -> :error
  end

  defp find_or_create_market_id(condition_id) do
    alias VolfefeMachine.Polymarket.Market

    case Repo.get_by(Market, condition_id: condition_id) do
      nil ->
        # Create a minimal placeholder market for this condition_id
        # This allows us to ingest trades for markets not yet in our API sync
        case %Market{}
             |> Market.changeset(%{
               condition_id: condition_id,
               question: "[Subgraph-discovered market]",
               is_active: false,
               meta: %{source: "subgraph", needs_sync: true}
             })
             |> Repo.insert(on_conflict: :nothing, returning: true) do
          {:ok, market} ->
            market.id

          {:error, _} ->
            # Race condition: another process created it, try to fetch again
            case Repo.get_by(Market, condition_id: condition_id) do
              nil -> nil
              market -> market.id
            end
        end

      existing ->
        existing.id
    end
  end

  defp ensure_wallet(address) do
    alias VolfefeMachine.Polymarket.Wallet

    case Repo.get_by(Wallet, address: address) do
      nil ->
        %Wallet{}
        |> Wallet.changeset(%{
          address: address,
          first_seen_at: DateTime.utc_now(),
          meta: %{source: "subgraph"}
        })
        |> Repo.insert(on_conflict: :nothing)

      _existing ->
        :ok
    end
  end

  defp parse_amount(nil), do: Decimal.new(0)
  defp parse_amount(str) when is_binary(str) do
    # Amounts are in wei (10^6 for USDC)
    case Integer.parse(str) do
      {amount, _} -> Decimal.div(Decimal.new(amount), Decimal.new(1_000_000))
      :error -> Decimal.new(0)
    end
  end

  defp parse_date_range(opts) do
    today = Date.utc_today()

    cond do
      opts[:days] ->
        from = Date.add(today, -opts[:days])
        {from, today}

      opts[:from] ->
        from = Date.from_iso8601!(opts[:from])
        to = if opts[:to], do: Date.from_iso8601!(opts[:to]), else: today
        {from, to}

      true ->
        # Default: last 7 days
        {Date.add(today, -7), today}
    end
  end

  defp date_to_unix(date) do
    date
    |> DateTime.new!(~T[00:00:00], "Etc/UTC")
    |> DateTime.to_unix()
  end

  defp percentage(_part, 0), do: "0.0"
  defp percentage(part, total) do
    Float.round(part / total * 100, 1)
  end

  defp print_subgraph_header do
    Mix.shell().info("")
    Mix.shell().info(String.duplicate("═", 65))
    Mix.shell().info("POLYMARKET SUBGRAPH INGESTION (Historical)")
    Mix.shell().info(String.duplicate("═", 65))
    Mix.shell().info("")
  end

  defp print_subgraph_footer do
    Mix.shell().info(String.duplicate("─", 65))
    Mix.shell().info("Re-run backtest: mix polymarket.backtest")
    Mix.shell().info("")
  end
end
