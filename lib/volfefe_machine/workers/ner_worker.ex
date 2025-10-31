defmodule VolfefeMachine.Workers.NerWorker do
  @moduledoc """
  Oban worker for processing Named Entity Recognition (NER) on individual content items.

  Extracts named entities (ORG, LOC, PER, MISC) using BERT-base-NER model
  and stores results in the classification metadata.

  ## Usage

      # Enqueue a NER job
      %{content_id: 123}
      |> VolfefeMachine.Workers.NerWorker.new()
      |> Oban.insert()

      # Schedule for later
      %{content_id: 123}
      |> VolfefeMachine.Workers.NerWorker.new(schedule_in: 60)
      |> Oban.insert()

  ## Job Arguments

    * `:content_id` - ID of the content to extract entities from (required)
    * `:force` - Force reprocessing even if already classified (optional, default: false)

  """

  use Oban.Worker,
    queue: :ml_ner,
    max_attempts: 3

  require Logger

  alias VolfefeMachine.{Content, Intelligence}

  @impl Oban.Worker
  def perform(%Oban.Job{args: %{"content_id" => content_id} = args}) do
    force = Map.get(args, "force", false)

    Logger.info("Processing NER for content_id=#{content_id}, force=#{force}")

    with :ok <- check_content_status(content_id, force),
         {:ok, _result} <- Intelligence.classify_content_multi_model(content_id) do
      # Don't auto-capture market snapshots - let user manually trigger from Market Data Dashboard
      Content.mark_as_classified(content_id, false)
      Logger.info("Successfully extracted entities for content_id=#{content_id}")
      :ok
    else
      {:error, :already_classified} ->
        Logger.info("Skipping content_id=#{content_id} - already classified")
        :ok

      {:error, reason} ->
        Logger.error("Failed to extract entities for content_id=#{content_id}: #{inspect(reason)}")
        {:error, reason}
    end
  end

  # Private functions

  defp check_content_status(content_id, force) do
    case Content.get_content(content_id) do
      nil ->
        {:error, :content_not_found}

      content ->
        if content.classified and not force do
          {:error, :already_classified}
        else
          :ok
        end
    end
  end
end
