defmodule Mix.Tasks.Polymarket.Ingest do
  @moduledoc """
  Ingest trades from Polymarket API.

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
  """

  use Mix.Task
  require Logger
  alias VolfefeMachine.Polymarket

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
        verbose: :boolean
      ],
      aliases: [m: :market, c: :category, l: :limit, v: :verbose]
    )

    print_header()

    cond do
      opts[:continuous] ->
        run_continuous(opts)

      opts[:market] ->
        ingest_market(opts[:market], opts)

      opts[:category] ->
        ingest_category(opts[:category], opts)

      opts[:all_active] ->
        ingest_all_active(opts)

      true ->
        # Default: recent trades
        ingest_recent(opts)
    end

    unless opts[:continuous] do
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
end
