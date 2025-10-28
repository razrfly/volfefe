defmodule VolfefeMachine.Workers.BatchReprocessWorker do
  @moduledoc """
  Oban worker for batch reprocessing of content with ML models.

  Coordinates large-scale reprocessing operations by enqueueing individual
  sentiment and NER jobs for each content item.

  ## Usage

      # Enqueue a batch reprocessing job
      %{content_ids: [1, 2, 3], model_type: "sentiment", force: true}
      |> VolfefeMachine.Workers.BatchReprocessWorker.new()
      |> Oban.insert()

      # Schedule for later
      %{content_ids: [1, 2, 3], model_type: "all"}
      |> VolfefeMachine.Workers.BatchReprocessWorker.new(schedule_in: 300)
      |> Oban.insert()

  ## Job Arguments

    * `:content_ids` - List of content IDs to process (required)
    * `:model_type` - Type of processing: "sentiment", "ner", or "all" (required)
    * `:force` - Force reprocessing even if already classified (optional, default: false)

  """

  use Oban.Worker,
    queue: :ml_batch,
    max_attempts: 1

  require Logger

  alias VolfefeMachine.Workers.{SentimentWorker, NerWorker}

  @impl Oban.Worker
  def perform(%Oban.Job{args: %{"content_ids" => content_ids, "model_type" => model_type} = args}) do
    force = Map.get(args, "force", false)
    total = length(content_ids)

    Logger.info("Starting batch reprocessing: #{total} items, model_type=#{model_type}, force=#{force}")

    jobs =
      content_ids
      |> Enum.with_index(1)
      |> Enum.flat_map(fn {content_id, index} ->
        build_jobs(content_id, model_type, force, index, total)
      end)

    inserted_jobs = Oban.insert_all(jobs)
    count = length(inserted_jobs)
    Logger.info("Enqueued #{count} jobs for batch reprocessing")
    :ok
  end

  # Private functions

  defp build_jobs(content_id, "sentiment", force, index, total) do
    Logger.debug("[#{index}/#{total}] Enqueueing sentiment job for content_id=#{content_id}")

    [
      SentimentWorker.new(%{content_id: content_id, force: force})
    ]
  end

  defp build_jobs(content_id, "ner", force, index, total) do
    Logger.debug("[#{index}/#{total}] Enqueueing NER job for content_id=#{content_id}")

    [
      NerWorker.new(%{content_id: content_id, force: force})
    ]
  end

  defp build_jobs(content_id, "all", force, index, total) do
    Logger.debug("[#{index}/#{total}] Enqueueing sentiment + NER jobs for content_id=#{content_id}")

    [
      SentimentWorker.new(%{content_id: content_id, force: force}),
      NerWorker.new(%{content_id: content_id, force: force})
    ]
  end

  defp build_jobs(content_id, unknown_type, _force, index, total) do
    Logger.warning("[#{index}/#{total}] Unknown model_type '#{unknown_type}' for content_id=#{content_id}, skipping")
    []
  end
end
