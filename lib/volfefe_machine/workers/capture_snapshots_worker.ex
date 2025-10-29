defmodule VolfefeMachine.Workers.CaptureSnapshotsWorker do
  @moduledoc """
  Oban worker for capturing market snapshots around individual content items.

  Captures 4 time-windowed snapshots (before, 1hr, 4hr, 24hr after) for each
  asset, storing OHLCV data, volume z-scores, and market state information.

  ## Usage

      # Enqueue a snapshot capture job
      %{content_id: 165}
      |> VolfefeMachine.Workers.CaptureSnapshotsWorker.new()
      |> Oban.insert()

      # Schedule for later with force recapture
      %{content_id: 165, force: true}
      |> VolfefeMachine.Workers.CaptureSnapshotsWorker.new(schedule_in: 300)
      |> Oban.insert()

  ## Job Arguments

    * `:content_id` - ID of the content to capture snapshots for (required)
    * `:force` - Force recapture even if snapshots exist (optional, default: false)

  """

  use Oban.Worker,
    queue: :market_snapshots,
    max_attempts: 3

  require Logger

  import Ecto.Query
  alias VolfefeMachine.{Content, MarketData, Repo}
  alias VolfefeMachine.MarketData.{Helpers, Snapshot, TwelveDataClient}

  @impl Oban.Worker
  def perform(%Oban.Job{id: job_id, args: %{"content_id" => content_id} = args}) do
    force = Map.get(args, "force", false)

    Logger.info("Capturing snapshots for content_id=#{content_id}, force=#{force}")

    with {:ok, content} <- get_content(content_id),
         :ok <- check_classification_status(content),
         {:ok, assets} <- get_assets() do

      results = capture_snapshots(content, assets, force)

      log_results(content_id, results)

      # Store results in job meta for visibility
      meta = %{
        content_id: content_id,
        success: results.success,
        skipped: results.skipped,
        failed: results.failed,
        total_assets: length(assets),
        windows: 4,
        completed_at: DateTime.utc_now() |> DateTime.to_iso8601()
      }

      # Update job meta
      from(j in Oban.Job, where: j.id == ^job_id)
      |> Repo.update_all(set: [meta: meta])

      :ok
    else
      {:error, :content_not_found} ->
        Logger.error("Content not found: content_id=#{content_id}")
        {:error, :content_not_found}

      {:error, :not_classified} ->
        Logger.warning("Content not classified: content_id=#{content_id}")
        {:error, :not_classified}

      {:error, :no_assets} ->
        Logger.error("No active assets found for snapshot capture")
        {:error, :no_assets}

      {:error, reason} ->
        Logger.error("Failed to capture snapshots for content_id=#{content_id}: #{inspect(reason)}")
        {:error, reason}
    end
  end

  # Private functions

  defp get_content(content_id) do
    case Content.get_content(content_id) do
      nil -> {:error, :content_not_found}
      content -> {:ok, content}
    end
  end

  defp check_classification_status(content) do
    if content.classified do
      :ok
    else
      {:error, :not_classified}
    end
  end

  defp get_assets do
    case MarketData.list_active() do
      [] -> {:error, :no_assets}
      assets -> {:ok, assets}
    end
  end

  defp capture_snapshots(content, assets, force) do
    # Calculate snapshot windows
    windows = Helpers.calculate_snapshot_windows(content.published_at)

    # Calculate isolation score
    {isolation_score, nearby_ids} =
      Helpers.calculate_isolation_score(content.id, content.published_at, 4)

    Logger.info("Content ##{content.id}: isolation_score=#{isolation_score}, nearby=#{length(nearby_ids)}")

    # Process each asset
    results = %{success: 0, skipped: 0, failed: 0, errors: []}

    Enum.reduce(assets, results, fn asset, acc ->
      process_asset_snapshots(asset, content, windows, isolation_score, force, acc)
    end)
  end

  defp process_asset_snapshots(asset, content, windows, isolation_score, force, results) do
    window_types = ["before", "1hr_after", "4hr_after", "24hr_after"]
    window_datetimes = [windows.before, windows.after_1hr, windows.after_4hr, windows.after_24hr]

    Enum.zip(window_types, window_datetimes)
    |> Enum.reduce(results, fn {window_type, timestamp}, acc ->
      capture_single_snapshot(asset, content, window_type, timestamp, isolation_score, force, acc)
    end)
  end

  defp capture_single_snapshot(asset, content, window_type, timestamp, isolation_score, force, results) do
    # Check if snapshot already exists
    existing = Repo.get_by(Snapshot,
      content_id: content.id,
      asset_id: asset.id,
      window_type: window_type
    )

    if existing && !force do
      Logger.debug("Skipped #{asset.symbol} #{window_type} for content ##{content.id}: exists")
      %{results | skipped: results.skipped + 1}
    else
      # Get baseline for this asset and window
      baseline = get_baseline(asset.id, window_type)

      # Capture snapshot from TwelveData
      case TwelveDataClient.get_bar_with_context(asset.symbol, timestamp, baseline) do
        {:ok, snapshot_attrs} ->
          snapshot_attrs = Map.merge(snapshot_attrs, %{
            content_id: content.id,
            asset_id: asset.id,
            window_type: window_type,
            isolation_score: isolation_score
          })

          case upsert_snapshot(existing, snapshot_attrs) do
            {:ok, _} ->
              Logger.info("Captured #{asset.symbol} #{window_type} for content ##{content.id}")
              %{results | success: results.success + 1}

            {:error, changeset} ->
              Logger.error("Failed to save #{asset.symbol} #{window_type} for content ##{content.id}: #{inspect(changeset.errors)}")
              %{results |
                failed: results.failed + 1,
                errors: [{asset.symbol, window_type, inspect(changeset.errors)} | results.errors]
              }
          end

        {:error, reason} ->
          Logger.warning("No data for #{asset.symbol} #{window_type} at #{timestamp}: #{reason}")
          %{results |
            failed: results.failed + 1,
            errors: [{asset.symbol, window_type, reason} | results.errors]
          }
      end
    end
  end

  defp get_baseline(asset_id, window_type) do
    window_minutes = case window_type do
      "before" -> 60
      "1hr_after" -> 60
      "4hr_after" -> 240
      "24hr_after" -> 1440
    end

    Repo.get_by(MarketData.BaselineStats,
      asset_id: asset_id,
      window_minutes: window_minutes
    )
  end

  defp upsert_snapshot(nil, attrs) do
    %Snapshot{}
    |> Snapshot.changeset(attrs)
    |> Repo.insert()
  end

  defp upsert_snapshot(existing, attrs) do
    existing
    |> Snapshot.changeset(attrs)
    |> Repo.update()
  end

  defp log_results(content_id, results) do
    Logger.info("""
    Snapshot capture complete for content_id=#{content_id}:
      ✅ Success: #{results.success}
      ⏭️  Skipped: #{results.skipped}
      ❌ Failed: #{results.failed}
    """)

    if results.failed > 0 do
      Enum.each(results.errors, fn {symbol, window, reason} ->
        Logger.warning("  #{symbol} #{window}: #{reason}")
      end)
    end
  end
end
