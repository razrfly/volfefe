defmodule VolfefeMachine.Intelligence.Reprocessor do
  @moduledoc """
  Service module for re-processing ML models on existing content.

  Provides flexible re-processing capabilities:
  - Rerun specific models or all models
  - Target specific content or all content
  - Filter by model type (sentiment vs NER)
  - Force overwrite or skip already processed
  - Dry run mode for previewing changes

  ## Usage

      # Rerun all models on unclassified content
      Reprocessor.reprocess(model: :all, limit: 10)

      # Rerun specific model on all content
      Reprocessor.reprocess(model: "finbert", all: true, force: true)

      # Rerun NER only on specific content
      Reprocessor.reprocess(model_type: :ner, content_ids: [1, 2, 3])

      # Preview what would be processed
      Reprocessor.reprocess(model: "twitter_roberta", limit: 10, dry_run: true)
  """

  import Ecto.Query
  require Logger

  alias VolfefeMachine.{Content, Intelligence, Repo}
  alias VolfefeMachine.Intelligence.ModelRegistry

  @type reprocess_opts :: [
          model: String.t() | atom() | :all,
          model_type: :sentiment | :ner | :all,
          content_ids: [integer()],
          limit: integer(),
          all: boolean(),
          force: boolean(),
          dry_run: boolean(),
          multi_model: boolean(),
          async: boolean()
        ]

  @type reprocess_result :: %{
          total: integer(),
          processed: integer(),
          skipped: integer(),
          failed: integer(),
          content_ids: [integer()],
          models_used: [String.t()],
          enqueued_jobs: integer() | nil,
          async: boolean()
        }

  @doc """
  Reprocess content with ML models based on provided options.

  ## Options

    * `:model` - Specific model ID to run, or `:all` for all models (default: :all)
    * `:model_type` - Filter by model type: `:sentiment`, `:ner`, or `:all` (default: :all)
    * `:content_ids` - Specific content IDs to process (optional)
    * `:limit` - Maximum number of items to process (default: 10)
    * `:all` - Process all matching content (overrides :limit)
    * `:force` - Reprocess even if already classified (default: false)
    * `:dry_run` - Preview what would be processed without running (default: false)
    * `:multi_model` - Use multi-model consensus for sentiment (default: true if model: :all)
    * `:async` - Enqueue jobs in Oban instead of processing immediately (default: false)

  ## Returns

    * `{:ok, result}` - Success with statistics
    * `{:error, reason}` - Failure reason

  ## Examples

      # Rerun finbert on unclassified content
      {:ok, result} = Reprocessor.reprocess(model: "finbert", limit: 10)

      # Rerun all sentiment models on specific content
      {:ok, result} = Reprocessor.reprocess(
        model_type: :sentiment,
        content_ids: [1, 2, 3],
        force: true
      )

      # Preview NER reprocessing
      {:ok, result} = Reprocessor.reprocess(
        model_type: :ner,
        all: true,
        dry_run: true
      )

      # Enqueue async jobs for batch processing
      {:ok, result} = Reprocessor.reprocess(
        model_type: :all,
        content_ids: [1, 2, 3],
        force: true,
        async: true
      )
  """
  @spec reprocess(reprocess_opts()) :: {:ok, reprocess_result()} | {:error, term()}
  def reprocess(opts \\ []) do
    with {:ok, content_ids} <- build_content_query(opts),
         {:ok, models} <- select_models(opts) do
      cond do
        opts[:dry_run] ->
          {:ok, preview_reprocessing(content_ids, models, opts)}

        opts[:async] ->
          enqueue_async_jobs(content_ids, models, opts)

        true ->
          run_reprocessing(content_ids, models, opts)
      end
    end
  end

  @doc """
  Builds an Ecto query for content based on reprocessing options.

  Used internally by `reprocess/1` but exposed for testing and debugging.
  """
  @spec build_content_query(reprocess_opts()) :: {:ok, [integer()]} | {:error, term()}
  def build_content_query(opts) do
    cond do
      # Specific IDs provided
      opts[:content_ids] && is_list(opts[:content_ids]) ->
        {:ok, opts[:content_ids]}

      # All content (with optional force)
      opts[:all] ->
        query = base_content_query(opts[:force] || false)
        {:ok, Repo.all(query)}

      # Limited number (default behavior)
      true ->
        limit = opts[:limit] || 10
        query = base_content_query(opts[:force] || false) |> limit(^limit)
        {:ok, Repo.all(query)}
    end
  end

  @doc """
  Selects which models to run based on options.

  Returns list of model IDs to execute.
  """
  @spec select_models(reprocess_opts()) :: {:ok, [String.t()]} | {:error, term()}
  def select_models(opts) do
    models =
      cond do
        # Specific model requested
        opts[:model] && opts[:model] != :all ->
          model_id = to_string(opts[:model])

          case ModelRegistry.get_model(model_id) do
            nil -> {:error, {:invalid_model, model_id}}
            model -> {:ok, [model.id]}
          end

        # Filter by model type
        opts[:model_type] && opts[:model_type] != :all ->
          models = ModelRegistry.models_by_type(opts[:model_type])
          {:ok, Enum.map(models, & &1.id)}

        # All models (default)
        true ->
          models = ModelRegistry.list_models()
          {:ok, Enum.map(models, & &1.id)}
      end

    case models do
      {:ok, []} -> {:error, :no_models_selected}
      result -> result
    end
  end

  # Private functions

  defp base_content_query(force) do
    base =
      from c in Content.Content,
        where: not is_nil(c.text) and c.text != "",
        order_by: [asc: c.id]

    q =
      if force do
        base
      else
        # Only unclassified content
        from c in base,
          left_join: cl in assoc(c, :classification),
          where: is_nil(cl.id)
      end

    from c in q, select: c.id
  end

  defp preview_reprocessing(content_ids, models, opts) do
    %{
      total: length(content_ids),
      processed: 0,
      skipped: 0,
      failed: 0,
      content_ids: content_ids,
      models_used: models,
      enqueued_jobs: nil,
      async: opts[:async] || false,
      dry_run: true
    }
  end

  defp enqueue_async_jobs(content_ids, models, opts) do
    force = opts[:force] || false
    model_type = determine_model_type(models)

    Logger.info("Enqueueing #{length(content_ids)} items for async reprocessing (model_type=#{model_type})")

    # Enqueue a single batch job that will handle all content items
    job =
      %{
        content_ids: content_ids,
        model_type: model_type,
        force: force
      }
      |> VolfefeMachine.Workers.BatchReprocessWorker.new()

    case Oban.insert(job) do
      {:ok, _job} ->
        Logger.info("Successfully enqueued batch reprocessing job")

        {:ok,
         %{
           total: length(content_ids),
           processed: 0,
           skipped: 0,
           failed: 0,
           content_ids: content_ids,
           models_used: models,
           enqueued_jobs: 1,
           async: true
         }}

      {:error, reason} ->
        {:error, {:enqueue_failed, reason}}
    end
  end

  defp determine_model_type(models) do
    model_types =
      Enum.map(models, fn model_id ->
        case ModelRegistry.get_model(model_id) do
          nil -> :unknown
          model -> String.to_atom(model.type)
        end
      end)
      |> Enum.uniq()

    cond do
      model_types == [:sentiment] -> "sentiment"
      model_types == [:ner] -> "ner"
      :sentiment in model_types and :ner in model_types -> "all"
      true -> "all"
    end
  end

  defp run_reprocessing(content_ids, models, opts) do
    multi_model = determine_multi_model_mode(models, opts)

    results =
      content_ids
      |> Enum.with_index(1)
      |> Enum.map(fn {content_id, index} ->
        process_content(content_id, models, multi_model, index, length(content_ids))
      end)

    summarize_results(results, models)
  end

  defp determine_multi_model_mode(models, opts) do
    # Use multi-model if explicitly requested, or if running all sentiment models
    cond do
      opts[:multi_model] == true -> true
      opts[:multi_model] == false -> false
      # Auto-detect: if multiple sentiment models selected, use multi-model
      length(sentiment_models_in_list(models)) > 1 -> true
      true -> false
    end
  end

  defp sentiment_models_in_list(model_ids) do
    Enum.filter(model_ids, fn model_id ->
      case ModelRegistry.get_model(model_id) do
        nil -> false
        model -> model.type == "sentiment"
      end
    end)
  end

  defp process_content(content_id, models, multi_model, index, total) do
    Logger.info("[#{index}/#{total}] Reprocessing content_id=#{content_id} with models: #{inspect(models)}")

    try do
      # Check if it's NER or sentiment
      model_types =
        Enum.map(models, fn model_id ->
          case ModelRegistry.get_model(model_id) do
            nil -> :unknown
            model -> String.to_atom(model.type)
          end
        end)
        |> Enum.uniq()

      cond do
        # Pure NER reprocessing
        model_types == [:ner] ->
          run_ner_only(content_id)

        # Pure sentiment reprocessing
        :sentiment in model_types and :ner not in model_types ->
          if multi_model do
            Intelligence.classify_content_multi_model(content_id)
          else
            Intelligence.classify_content(content_id)
          end

        # Mixed (both sentiment and NER)
        true ->
          Intelligence.classify_content_multi_model(content_id)
      end
      |> handle_classification_result(content_id)
    rescue
      error ->
        Logger.error("Failed to reprocess content_id=#{content_id}: #{inspect(error)}")
        {:error, content_id, error}
    end
  end

  defp run_ner_only(content_id) do
    # For NER-only, we need to call the extraction separately
    # This assumes the multi_model_client returns entity data
    case Intelligence.classify_content_multi_model(content_id) do
      {:ok, result} ->
        # Just return the entities part
        {:ok, %{entities: result.metadata[:entities] || result.metadata["entities"]}}

      error ->
        error
    end
  end

  defp handle_classification_result(result, content_id) do
    case result do
      {:ok, _classification_or_result} ->
        # Handles both single-model {:ok, classification} and multi-model {:ok, %{consensus: ...}}
        # Don't auto-capture market snapshots - let user manually trigger from Market Data Dashboard
        Content.mark_as_classified(content_id, false)
        {:ok, content_id}

      {:error, reason} ->
        {:error, content_id, reason}
    end
  end

  defp summarize_results(results, models) do
    successful = Enum.count(results, &match?({:ok, _}, &1))
    failed = Enum.count(results, &match?({:error, _, _}, &1))

    {:ok,
     %{
       total: length(results),
       processed: successful,
       skipped: 0,
       failed: failed,
       content_ids: Enum.map(results, fn r -> elem(r, 1) end),
       models_used: models
     }}
  end
end
