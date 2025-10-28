defmodule VolfefeMachine.Workers.CalculateBaselinesWorker do
  @moduledoc """
  Oban worker for calculating baseline statistics for individual assets.

  Fetches historical market data and computes rolling return statistics
  (mean, std dev, percentiles) for 1hr, 4hr, and 24hr time windows.

  ## Usage

      # Enqueue a baseline calculation job
      %{asset_id: 1, lookback_days: 60}
      |> VolfefeMachine.Workers.CalculateBaselinesWorker.new()
      |> Oban.insert()

      # Schedule for later with force recalculation
      %{asset_id: 1, lookback_days: 60, force: true}
      |> VolfefeMachine.Workers.CalculateBaselinesWorker.new(schedule_in: 300)
      |> Oban.insert()

  ## Job Arguments

    * `:asset_id` - ID of the asset to calculate baselines for (required)
    * `:lookback_days` - Number of days of historical data (optional, default: 60)
    * `:force` - Force recalculation even if baselines exist (optional, default: false)
    * `:check_freshness` - Skip if baselines updated within 24hrs (optional, default: false)

  """

  use Oban.Worker,
    queue: :market_baselines,
    max_attempts: 3

  require Logger

  alias VolfefeMachine.{MarketData, Repo}
  alias VolfefeMachine.MarketData.{TwelveDataClient, BaselineStats}
  import Ecto.Query

  @time_windows [60, 240, 1440]  # 1hr, 4hr, 24hr in minutes
  @data_provider TwelveDataClient

  @impl Oban.Worker
  def perform(%Oban.Job{args: %{"asset_id" => asset_id} = args}) do
    lookback_days = Map.get(args, "lookback_days", 60)
    force = Map.get(args, "force", false)
    check_freshness = Map.get(args, "check_freshness", false)

    Logger.info("Calculating baselines for asset_id=#{asset_id}, lookback=#{lookback_days}, force=#{force}, check_freshness=#{check_freshness}")

    with {:ok, asset} <- get_asset(asset_id),
         :ok <- check_freshness_status(asset_id, force, check_freshness),
         {:ok, bars} <- fetch_historical_bars(asset.symbol, lookback_days) do

      calculate_all_windows(asset, bars, force, check_freshness)

      Logger.info("Successfully calculated baselines for asset_id=#{asset_id} (#{asset.symbol})")

      meta = %{
        asset_id: asset_id,
        symbol: asset.symbol,
        windows_calculated: length(@time_windows),
        lookback_days: lookback_days,
        bars_processed: length(bars),
        completed_at: DateTime.utc_now() |> DateTime.to_iso8601()
      }

      {:ok, meta}
    else
      {:error, :all_fresh} ->
        Logger.info("Skipping asset_id=#{asset_id} - all baselines are fresh (<24hrs)")
        {:ok, %{asset_id: asset_id, skipped: true, reason: "all_fresh"}}

      {:error, :asset_not_found} ->
        Logger.error("Asset not found: asset_id=#{asset_id}")
        {:error, :asset_not_found}

      {:error, :no_data} ->
        Logger.warning("No historical data available for asset_id=#{asset_id}")
        {:error, :no_data}

      {:error, reason} ->
        Logger.error("Failed to calculate baselines for asset_id=#{asset_id}: #{inspect(reason)}")
        {:error, reason}
    end
  end

  # Private functions

  defp get_asset(asset_id) do
    case Repo.get(MarketData.Asset, asset_id) do
      nil -> {:error, :asset_not_found}
      asset -> {:ok, asset}
    end
  end

  defp check_freshness_status(asset_id, force, check_freshness) do
    if check_freshness and not force and all_baselines_fresh?(asset_id) do
      {:error, :all_fresh}
    else
      :ok
    end
  end

  defp all_baselines_fresh?(asset_id) do
    cutoff = DateTime.add(DateTime.utc_now(), -86400, :second) # 24 hours ago

    fresh_count = from(b in BaselineStats,
      where: b.asset_id == ^asset_id and b.updated_at > ^cutoff,
      select: count(b.id)
    ) |> Repo.one()

    fresh_count == length(@time_windows)
  end

  defp fetch_historical_bars(symbol, lookback_days) do
    end_date = DateTime.utc_now()
    start_date = DateTime.add(end_date, -lookback_days * 86400, :second)

    case @data_provider.get_bars(symbol, start_date, end_date, timeframe: "1Hour") do
      {:ok, []} -> {:error, :no_data}
      {:ok, bars} -> {:ok, bars}
      error -> error
    end
  end

  defp calculate_all_windows(asset, bars, force, check_freshness) do
    Enum.each(@time_windows, fn window_minutes ->
      calculate_and_store_baseline(asset, bars, window_minutes, force, check_freshness)
    end)
  end

  defp calculate_and_store_baseline(asset, bars, window_minutes, force, check_freshness) do
    returns = calculate_rolling_returns(bars, window_minutes)
    volumes = Enum.map(bars, & &1.volume)

    if length(returns) < 10 do
      Logger.warning("Insufficient data for #{asset.symbol} #{format_window(window_minutes)}: #{length(returns)} samples")
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
              Logger.info("Created baseline for #{asset.symbol} #{format_window(window_minutes)}: μ=#{Float.round(stats.mean_return, 4)}%, σ=#{Float.round(stats.std_dev, 4)}%")
            {:error, changeset} ->
              Logger.error("Failed to create baseline for #{asset.symbol} #{format_window(window_minutes)}: #{inspect(changeset.errors)}")
          end

        existing when force ->
          case update_baseline_stats(existing, stats) do
            {:ok, _} ->
              Logger.info("Updated baseline for #{asset.symbol} #{format_window(window_minutes)} (forced)")
            {:error, changeset} ->
              Logger.error("Failed to update baseline for #{asset.symbol} #{format_window(window_minutes)}: #{inspect(changeset.errors)}")
          end

        existing ->
          if check_freshness and baseline_is_fresh?(existing) do
            Logger.debug("Skipped #{asset.symbol} #{format_window(window_minutes)}: fresh (updated #{format_age(existing.updated_at)})")
          else
            Logger.debug("Skipped #{asset.symbol} #{format_window(window_minutes)}: exists (use force to update)")
          end
      end
    end
  end

  # Statistical calculations

  defp calculate_rolling_returns(bars, window_minutes) do
    window_bars = div(window_minutes, 60)

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

  # Database operations

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

  defp baseline_is_fresh?(baseline) do
    cutoff = DateTime.add(DateTime.utc_now(), -86400, :second)
    DateTime.compare(baseline.updated_at, cutoff) == :gt
  end

  # Formatting helpers

  defp format_window(60), do: "1hr"
  defp format_window(240), do: "4hr"
  defp format_window(1440), do: "24hr"
  defp format_window(minutes), do: "#{minutes}min"

  defp format_age(datetime) do
    now = DateTime.utc_now()
    diff_seconds = DateTime.diff(now, datetime)

    cond do
      diff_seconds < 3600 ->
        minutes = div(diff_seconds, 60)
        "#{minutes}m ago"
      diff_seconds < 86400 ->
        hours = div(diff_seconds, 3600)
        "#{hours}h ago"
      true ->
        days = div(diff_seconds, 86400)
        "#{days}d ago"
    end
  end
end
