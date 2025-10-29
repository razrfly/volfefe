defmodule VolfefeMachine.MarketData.Jobs do
  @moduledoc """
  Helper functions for enqueueing market data processing jobs.

  Provides convenient interfaces for scheduling baseline calculations
  and snapshot captures via Oban workers.

  ## Examples

      # Calculate baselines for single asset
      MarketData.Jobs.calculate_baselines(asset_id: 1)

      # Calculate baselines for multiple assets
      MarketData.Jobs.calculate_baselines_batch([1, 2, 3], lookback_days: 60, force: true)

      # Capture snapshots for single content
      MarketData.Jobs.capture_snapshots(content_id: 165)

      # Capture snapshots for multiple content
      MarketData.Jobs.capture_snapshots_batch([165, 166, 167])

  """

  alias VolfefeMachine.Workers.{
    CalculateBaselinesWorker,
    CaptureSnapshotsWorker,
    BatchMarketDataWorker
  }

  @doc """
  Enqueue a baseline calculation job for a single asset.

  ## Options

    * `:asset_id` - Asset ID (required)
    * `:lookback_days` - Lookback period (optional, default: 60)
    * `:force` - Force recalculation (optional, default: false)
    * `:check_freshness` - Skip if fresh <24hrs (optional, default: false)
    * `:schedule_in` - Delay in seconds (optional)

  ## Examples

      MarketData.Jobs.calculate_baselines(asset_id: 1)
      MarketData.Jobs.calculate_baselines(asset_id: 1, force: true, lookback_days: 90)
      MarketData.Jobs.calculate_baselines(asset_id: 1, schedule_in: 300)

  """
  def calculate_baselines(opts) do
    asset_id = Keyword.fetch!(opts, :asset_id)
    lookback_days = Keyword.get(opts, :lookback_days, 60)
    force = Keyword.get(opts, :force, false)
    check_freshness = Keyword.get(opts, :check_freshness, false)
    schedule_in = Keyword.get(opts, :schedule_in)

    job_args = %{
      asset_id: asset_id,
      lookback_days: lookback_days,
      force: force,
      check_freshness: check_freshness
    }

    job = if schedule_in do
      CalculateBaselinesWorker.new(job_args, schedule_in: schedule_in)
    else
      CalculateBaselinesWorker.new(job_args)
    end

    Oban.insert(job)
  end

  @doc """
  Enqueue baseline calculation jobs for multiple assets.

  ## Arguments

    * `asset_ids` - List of asset IDs
    * `opts` - Options keyword list
      * `:lookback_days` - Lookback period (optional, default: 60)
      * `:force` - Force recalculation (optional, default: false)
      * `:check_freshness` - Skip if fresh (optional, default: false)
      * `:schedule_in` - Delay in seconds (optional)

  ## Examples

      MarketData.Jobs.calculate_baselines_batch([1, 2, 3])
      MarketData.Jobs.calculate_baselines_batch([1, 2, 3], force: true, lookback_days: 90)

  """
  def calculate_baselines_batch(asset_ids, opts \\ []) when is_list(asset_ids) do
    if asset_ids == [] do
      {:error, :empty_asset_ids}
    else
      lookback_days = Keyword.get(opts, :lookback_days, 60)
      force = Keyword.get(opts, :force, false)
      check_freshness = Keyword.get(opts, :check_freshness, false)
      schedule_in = Keyword.get(opts, :schedule_in)

      job_args = %{
        operation: "baselines",
        asset_ids: asset_ids,
        lookback_days: lookback_days,
        force: force,
        check_freshness: check_freshness
      }

      job = if schedule_in do
        BatchMarketDataWorker.new(job_args, schedule_in: schedule_in)
      else
        BatchMarketDataWorker.new(job_args)
      end

      Oban.insert(job)
    end
  end

  @doc """
  Enqueue a snapshot capture job for a single content item.

  ## Options

    * `:content_id` - Content ID (required)
    * `:force` - Force recapture (optional, default: false)
    * `:schedule_in` - Delay in seconds (optional)

  ## Examples

      MarketData.Jobs.capture_snapshots(content_id: 165)
      MarketData.Jobs.capture_snapshots(content_id: 165, force: true)
      MarketData.Jobs.capture_snapshots(content_id: 165, schedule_in: 3600)

  """
  def capture_snapshots(opts) do
    content_id = Keyword.fetch!(opts, :content_id)
    force = Keyword.get(opts, :force, false)
    schedule_in = Keyword.get(opts, :schedule_in)

    job_args = %{
      content_id: content_id,
      force: force
    }

    job = if schedule_in do
      CaptureSnapshotsWorker.new(job_args, schedule_in: schedule_in)
    else
      CaptureSnapshotsWorker.new(job_args)
    end

    Oban.insert(job)
  end

  @doc """
  Enqueue snapshot capture jobs for multiple content items.

  ## Arguments

    * `content_ids` - List of content IDs
    * `opts` - Options keyword list
      * `:force` - Force recapture (optional, default: false)
      * `:schedule_in` - Delay in seconds (optional)

  ## Examples

      MarketData.Jobs.capture_snapshots_batch([165, 166, 167])
      MarketData.Jobs.capture_snapshots_batch([165, 166, 167], force: true)

  """
  def capture_snapshots_batch(content_ids, opts \\ []) when is_list(content_ids) do
    if content_ids == [] do
      {:error, :empty_content_ids}
    else
      force = Keyword.get(opts, :force, false)
      schedule_in = Keyword.get(opts, :schedule_in)

      job_args = %{
        operation: "snapshots",
        content_ids: content_ids,
        force: force
      }

      job = if schedule_in do
        BatchMarketDataWorker.new(job_args, schedule_in: schedule_in)
      else
        BatchMarketDataWorker.new(job_args)
      end

      Oban.insert(job)
    end
  end

  @doc """
  Enqueue snapshot capture for a content item.

  This is a convenience function that schedules snapshot captures
  after the content is classified.

  ## Options

    * `:content_id` - Content ID (required)
    * `:delay` - Delay before capture in seconds (optional, default: 0)

  ## Examples

      # Capture snapshots immediately after classification
      MarketData.Jobs.enqueue_for_content(content_id: 165)

      # Capture snapshots 5 minutes after classification
      MarketData.Jobs.enqueue_for_content(content_id: 165, delay: 300)

  """
  def enqueue_for_content(opts) do
    content_id = Keyword.fetch!(opts, :content_id)
    delay = Keyword.get(opts, :delay, 0)

    capture_snapshots(content_id: content_id, schedule_in: delay)
  end

  @doc """
  Get job status and statistics for market data operations.

  ## Examples

      # Get all market data jobs
      MarketData.Jobs.get_job_stats()

      # Get jobs for specific operation
      MarketData.Jobs.get_job_stats(operation: "baselines")

  """
  def get_job_stats(opts \\ []) do
    import Ecto.Query

    base_query = from(j in Oban.Job,
      where: j.queue in ["market_baselines", "market_snapshots", "market_batch"]
    )

    query = case Keyword.get(opts, :operation) do
      "baselines" ->
        from(j in base_query, where: j.queue == "market_baselines")
      "snapshots" ->
        from(j in base_query, where: j.queue == "market_snapshots")
      "batch" ->
        from(j in base_query, where: j.queue == "market_batch")
      _ ->
        base_query
    end

    stats = from(j in query,
      group_by: j.state,
      select: {j.state, count(j.id)}
    )
    |> VolfefeMachine.Repo.all()
    |> Enum.into(%{})

    %{
      available: Map.get(stats, "available", 0),
      executing: Map.get(stats, "executing", 0),
      scheduled: Map.get(stats, "scheduled", 0),
      completed: Map.get(stats, "completed", 0),
      retryable: Map.get(stats, "retryable", 0),
      discarded: Map.get(stats, "discarded", 0),
      cancelled: Map.get(stats, "cancelled", 0)
    }
  end
end
