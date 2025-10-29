defmodule VolfefeMachine.Workers.BatchMarketDataWorker do
  @moduledoc """
  Oban worker for batch market data operations.

  Coordinates large-scale market data processing operations by enqueueing
  individual baseline calculation and snapshot capture jobs.

  ## Usage

      # Enqueue batch baseline calculation for multiple assets
      %{asset_ids: [1, 2, 3], operation: "baselines", lookback_days: 60}
      |> VolfefeMachine.Workers.BatchMarketDataWorker.new()
      |> Oban.insert()

      # Enqueue batch snapshot capture for multiple content items
      %{content_ids: [165, 166, 167], operation: "snapshots"}
      |> VolfefeMachine.Workers.BatchMarketDataWorker.new()
      |> Oban.insert()

      # Schedule batch operation for later
      %{asset_ids: [1, 2, 3], operation: "baselines", force: true}
      |> VolfefeMachine.Workers.BatchMarketDataWorker.new(schedule_in: 300)
      |> Oban.insert()

  ## Job Arguments

    * `:operation` - Type of operation: "baselines" or "snapshots" (required)
    * `:asset_ids` - List of asset IDs (required for baselines)
    * `:content_ids` - List of content IDs (required for snapshots)
    * `:lookback_days` - Lookback period for baselines (optional, default: 60)
    * `:force` - Force recalculation/recapture (optional, default: false)
    * `:check_freshness` - Skip fresh baselines (optional, default: false)

  """

  use Oban.Worker,
    queue: :market_batch,
    max_attempts: 1

  require Logger

  alias VolfefeMachine.Workers.{CalculateBaselinesWorker, CaptureSnapshotsWorker}

  @impl Oban.Worker
  def perform(%Oban.Job{args: %{"operation" => operation} = args}) do
    case operation do
      "baselines" ->
        process_baseline_batch(args)

      "snapshots" ->
        process_snapshot_batch(args)

      unknown ->
        Logger.warning("Unknown batch operation: #{unknown}")
        {:error, :unknown_operation}
    end
  end

  # Private functions

  defp process_baseline_batch(%{"asset_ids" => asset_ids} = args) do
    lookback_days = Map.get(args, "lookback_days", 60)
    force = Map.get(args, "force", false)
    check_freshness = Map.get(args, "check_freshness", false)
    total = length(asset_ids)

    Logger.info("Starting batch baseline calculation: #{total} assets, lookback=#{lookback_days}, force=#{force}, check_freshness=#{check_freshness}")

    jobs =
      asset_ids
      |> Enum.with_index(1)
      |> Enum.map(fn {asset_id, index} ->
        Logger.debug("[#{index}/#{total}] Enqueueing baseline job for asset_id=#{asset_id}")

        CalculateBaselinesWorker.new(%{
          asset_id: asset_id,
          lookback_days: lookback_days,
          force: force,
          check_freshness: check_freshness
        })
      end)

    case Oban.insert_all(jobs) do
      {:ok, inserted_jobs} ->
        count = length(inserted_jobs)
        Logger.info("Enqueued #{count} baseline calculation jobs")

        meta = %{
          operation: "baselines",
          total_assets: total,
          jobs_enqueued: count,
          lookback_days: lookback_days,
          force: force,
          check_freshness: check_freshness,
          completed_at: DateTime.utc_now() |> DateTime.to_iso8601()
        }

        {:ok, meta}

      {:error, reason} = error ->
        Logger.error("Failed to enqueue baseline jobs: #{inspect(reason)}")
        error
    end
  end

  defp process_baseline_batch(_args) do
    Logger.error("Missing asset_ids for baseline batch operation")
    {:error, :missing_asset_ids}
  end

  defp process_snapshot_batch(%{"content_ids" => content_ids} = args) do
    force = Map.get(args, "force", false)
    total = length(content_ids)

    Logger.info("Starting batch snapshot capture: #{total} content items, force=#{force}")

    jobs =
      content_ids
      |> Enum.with_index(1)
      |> Enum.map(fn {content_id, index} ->
        Logger.debug("[#{index}/#{total}] Enqueueing snapshot job for content_id=#{content_id}")

        CaptureSnapshotsWorker.new(%{
          content_id: content_id,
          force: force
        })
      end)

    case Oban.insert_all(jobs) do
      {:ok, inserted_jobs} ->
        count = length(inserted_jobs)
        Logger.info("Enqueued #{count} snapshot capture jobs")

        meta = %{
          operation: "snapshots",
          total_content: total,
          jobs_enqueued: count,
          force: force,
          completed_at: DateTime.utc_now() |> DateTime.to_iso8601()
        }

        {:ok, meta}

      {:error, reason} = error ->
        Logger.error("Failed to enqueue snapshot jobs: #{inspect(reason)}")
        error
    end
  end

  defp process_snapshot_batch(_args) do
    Logger.error("Missing content_ids for snapshot batch operation")
    {:error, :missing_content_ids}
  end
end
