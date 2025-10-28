defmodule Mix.Tasks.Calculate.Baselines do
  @moduledoc """
  Calculates baseline statistics from historical market data.

  For each asset and time window (1hr, 4hr, 24hr):
  1. Fetch 60 days of 1hr bars from TwelveData
  2. Calculate rolling returns for each window
  3. Compute mean, std_dev, percentiles
  4. Store in asset_baseline_stats

  ## Usage

      # Calculate baselines for all assets (60 days lookback)
      mix calculate.baselines --all

      # Calculate for specific asset
      mix calculate.baselines --symbol SPY --lookback-days 60

      # Recalculate (update existing)
      mix calculate.baselines --all --force

      # Dry run
      mix calculate.baselines --symbol SPY --dry-run

  ## Examples

      # After running, you can query the baseline stats:
      baseline = Repo.get_by(BaselineStats, asset_id: spy_id, window_minutes: 60)
      # Result: SPY typically moves ±0.3% per hour (z-score of 2.0 = 0.6% move)
  """

  use Mix.Task
  alias VolfefeMachine.{MarketData, Repo}
  alias VolfefeMachine.MarketData.{TwelveDataClient, BaselineStats}
  import Ecto.Query

  @shortdoc "Calculate baseline statistics from historical data"

  @time_windows [60, 240, 1440]  # 1hr, 4hr, 24hr in minutes
  @data_provider TwelveDataClient  # Use TwelveData for historical data (60+ days, 800 calls/day)

  @impl Mix.Task
  def run(args) do
    # Load .env file
    load_env_file()

    Mix.Task.run("app.start")

    {opts, _, _} = OptionParser.parse(args,
      switches: [all: :boolean, symbol: :string, lookback_days: :integer, force: :boolean, dry_run: :boolean],
      aliases: [a: :all, s: :symbol, l: :lookback_days, f: :force, d: :dry_run]
    )

    lookback_days = opts[:lookback_days] || 60

    assets = if opts[:all] do
      MarketData.list_active()
    else
      symbol = opts[:symbol]
      if symbol do
        case MarketData.get_by_symbol(symbol) do
          {:ok, asset} -> [asset]
          {:error, :not_found} ->
            Mix.shell().error("Asset not found: #{symbol}")
            System.halt(1)
        end
      else
        Mix.shell().error("Must specify --all or --symbol")
        print_usage()
        System.halt(1)
      end
    end

    Mix.shell().info("\n📊 Calculating baselines for #{length(assets)} assets...")
    Mix.shell().info("Lookback period: #{lookback_days} days\n")

    if opts[:dry_run] do
      dry_run(assets, lookback_days)
    else
      calculate_all(assets, lookback_days, opts[:force] || false)
    end
  end

  defp calculate_all(assets, lookback_days, force) do
    Enum.each(assets, fn asset ->
      Mix.shell().info("[#{asset.symbol}] Fetching historical data...")

      case fetch_historical_bars(asset.symbol, lookback_days) do
        {:ok, [_ | _] = bars} ->
          Mix.shell().info("  Found #{length(bars)} bars")

          Enum.each(@time_windows, fn window_minutes ->
            calculate_and_store_baseline(asset, bars, window_minutes, force)
          end)

        {:ok, []} ->
          Mix.shell().error("  ❌ No bars returned")

        {:error, reason} ->
          Mix.shell().error("  ❌ Failed: #{reason}")
      end

      # Rate limiting
      Process.sleep(200)
    end)

    print_summary()
  end

  defp fetch_historical_bars(symbol, lookback_days) do
    end_date = DateTime.utc_now()
    start_date = DateTime.add(end_date, -lookback_days * 86400, :second)

    # Fetch 1hr bars for full lookback period using configured provider
    # Default: AlphaVantageClient (supports 60+ days of historical data)
    @data_provider.get_bars(symbol, start_date, end_date, timeframe: "1Hour")
  end

  defp calculate_and_store_baseline(asset, bars, window_minutes, force) do
    # Calculate rolling returns for this window
    returns = calculate_rolling_returns(bars, window_minutes)
    volumes = Enum.map(bars, & &1.volume)

    if length(returns) < 10 do
      Mix.shell().info("  ⏭️  #{window_minutes}min: Insufficient data (#{length(returns)} samples)")
    else
      stats = %{
      asset_id: asset.id,
      window_minutes: window_minutes,
      mean_return: mean(returns),
      std_dev: std_dev(returns),
      percentile_50: percentile(returns, 0.50),
      percentile_95: percentile(returns, 0.95),
      percentile_99: percentile(returns, 0.99),
      mean_volume: trunc(mean(volumes)),
      volume_std_dev: trunc(std_dev(volumes)),
      sample_size: length(returns),
      sample_period_start: List.first(bars).timestamp,
      sample_period_end: List.last(bars).timestamp
    }

    case get_existing_baseline(asset.id, window_minutes) do
      nil ->
        case create_baseline_stats(stats) do
          {:ok, _} ->
            Mix.shell().info("  ✅ #{format_window(window_minutes)}: μ=#{format_pct(stats.mean_return)}%, σ=#{format_pct(stats.std_dev)}% (n=#{stats.sample_size})")
          {:error, changeset} ->
            Mix.shell().error("  ❌ #{format_window(window_minutes)}: #{inspect(changeset.errors)}")
        end

      existing when force ->
        case update_baseline_stats(existing, stats) do
          {:ok, _} ->
            Mix.shell().info("  🔄 #{format_window(window_minutes)}: Updated")
          {:error, changeset} ->
            Mix.shell().error("  ❌ #{format_window(window_minutes)}: #{inspect(changeset.errors)}")
        end

      _existing ->
        Mix.shell().info("  ⏭️  #{format_window(window_minutes)}: Skipped (exists, use --force to update)")
      end
    end
  end

  defp calculate_rolling_returns(bars, window_minutes) do
    window_bars = div(window_minutes, 60)  # Convert to number of 1hr bars

    bars
    |> Enum.chunk_every(window_bars + 1, 1, :discard)
    |> Enum.map(fn chunk ->
      start_price = List.first(chunk).close
      end_price = List.last(chunk).close

      Decimal.sub(end_price, start_price)
      |> Decimal.div(start_price)
      |> Decimal.mult(Decimal.new(100))
      |> Decimal.to_float()
    end)
  end

  # Statistical functions

  defp mean(values) do
    if length(values) == 0 do
      0.0
    else
      Enum.sum(values) / length(values)
    end
  end

  defp std_dev(values) do
    if length(values) < 2 do
      0.0
    else
      avg = mean(values)
      variance = Enum.map(values, fn x -> :math.pow(x - avg, 2) end) |> mean()
      :math.sqrt(variance)
    end
  end

  defp percentile(values, p) do
    if length(values) == 0 do
      0.0
    else
      sorted = Enum.sort(values)
      index = min(round(p * length(sorted)), length(sorted) - 1)
      Enum.at(sorted, index)
    end
  end

  # Database functions

  defp get_existing_baseline(asset_id, window_minutes) do
    from(b in BaselineStats,
      where: b.asset_id == ^asset_id and b.window_minutes == ^window_minutes
    )
    |> Repo.one()
  end

  defp create_baseline_stats(attrs) do
    %BaselineStats{}
    |> BaselineStats.changeset(attrs)
    |> Repo.insert()
  end

  defp update_baseline_stats(baseline, attrs) do
    baseline
    |> BaselineStats.changeset(attrs)
    |> Repo.update()
  end

  # Display functions

  defp dry_run(assets, lookback_days) do
    Mix.shell().info("\n🔍 DRY RUN - Would calculate baselines for:\n")

    Enum.each(assets, fn asset ->
      Mix.shell().info("  #{asset.symbol}: #{asset.name}")
      Mix.shell().info("    Windows: #{Enum.map_join(@time_windows, ", ", &format_window/1)}")
    end)

    Mix.shell().info("\nLookback period: #{lookback_days} days")
    Mix.shell().info("Expected API calls: #{length(assets)} assets × 1 historical fetch each")
    Mix.shell().info("\nRun without --dry-run to calculate.\n")
  end

  defp print_summary do
    count = Repo.aggregate(BaselineStats, :count)

    Mix.shell().info("\n" <> String.duplicate("=", 60))
    Mix.shell().info("📊 BASELINE CALCULATION SUMMARY")
    Mix.shell().info(String.duplicate("=", 60))
    Mix.shell().info("Total baseline stats in database: #{count}")
    Mix.shell().info("Expected: #{count_assets() * length(@time_windows)}")
    Mix.shell().info("\n✅ Baseline calculation complete!\n")
  end

  defp count_assets do
    from(a in MarketData.Asset, where: a.status == :active and a.tradable == true)
    |> Repo.aggregate(:count)
  end

  defp format_window(60), do: "1hr"
  defp format_window(240), do: "4hr"
  defp format_window(1440), do: "24hr"
  defp format_window(minutes), do: "#{minutes}min"

  defp format_pct(decimal) when is_float(decimal), do: Float.round(decimal, 4)
  defp format_pct(%Decimal{} = decimal), do: Decimal.to_float(decimal) |> Float.round(4)
  defp format_pct(nil), do: "N/A"

  defp print_usage do
    Mix.shell().info("""

    Usage:
      mix calculate.baselines --all
      mix calculate.baselines --symbol SPY --lookback-days 60
      mix calculate.baselines --all --force
      mix calculate.baselines --symbol SPY --dry-run
    """)
  end

  # Load environment variables from .env file
  defp load_env_file do
    env_file = ".env"

    if File.exists?(env_file) do
      env_file
      |> File.read!()
      |> String.split("\n")
      |> Enum.each(fn line ->
        line = String.trim(line)

        unless line == "" or String.starts_with?(line, "#") do
          case String.split(line, "=", parts: 2) do
            [key, value] ->
              value = String.trim(value)
              value = String.trim(value, "\"")
              value = String.trim(value, "'")
              System.put_env(key, value)
            _ ->
              :ok
          end
        end
      end)
    end
  end
end
