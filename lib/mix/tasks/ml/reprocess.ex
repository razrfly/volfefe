defmodule Mix.Tasks.Ml.Reprocess do
  @moduledoc """
  Reprocess content with ML models (sentiment analysis + entity extraction).

  This task provides flexible re-processing capabilities for existing content:
  - Run specific models or all models
  - Target specific content or all content
  - Filter by model type (sentiment vs NER)
  - Force overwrite existing classifications
  - Dry run mode to preview changes

  ## Usage

      # Rerun specific model on unclassified content
      mix ml.reprocess --model finbert --limit 10

      # Rerun all models on all content (force reprocess)
      mix ml.reprocess --all --force

      # Rerun only NER model on all content
      mix ml.reprocess --type ner --all --force

      # Rerun sentiment models only
      mix ml.reprocess --type sentiment --limit 50

      # Rerun specific model on specific content IDs
      mix ml.reprocess --model twitter_roberta --ids 1,2,3,4,5

      # Preview what would be processed (dry run)
      mix ml.reprocess --model finbert --limit 10 --dry-run

  ## Options

    * `--model MODEL` - Specific model to run (finbert, distilbert, twitter_roberta, bert_base_ner)
    * `--type TYPE` - Model type filter: sentiment, ner, or all (default: all)
    * `--ids IDS` - Comma-separated content IDs to process
    * `--limit N` - Maximum number of items to process (default: 10)
    * `--all` - Process all matching content (overrides --limit)
    * `--force` - Reprocess even if already classified (default: false)
    * `--dry-run` - Preview without actually processing
    * `--async` - Enqueue jobs for background processing (default: false)
    * `--multi-model` - Force multi-model mode for sentiment (default: auto)
    * `--no-multi-model` - Disable multi-model mode

  ## Examples

      # Fix NER bug - rerun entity extraction on all content
      mix ml.reprocess --type ner --all --force

      # Test new sentiment model on small sample
      mix ml.reprocess --model twitter_roberta --limit 5 --force

      # Backfill unclassified content
      mix ml.reprocess --all

      # Preview large operation before running
      mix ml.reprocess --type sentiment --all --force --dry-run

      # Enqueue jobs for background processing
      mix ml.reprocess --type ner --all --force --async

  ## Model IDs

  **Sentiment Models**:
  - `finbert` - FinBERT (financial sentiment)
  - `distilbert` - DistilBERT (general sentiment)
  - `twitter_roberta` - Twitter-RoBERTa (social media sentiment)

  **NER Models**:
  - `bert_base_ner` - BERT-base-NER (entity extraction: ORG, LOC, PER, MISC)

  Use `--model all` or omit to run all enabled models.
  """

  use Mix.Task

  alias VolfefeMachine.Intelligence.{ModelRegistry, Reprocessor}

  require Logger

  @shortdoc "Reprocess content with ML models (flexible model/content selection)"

  @impl Mix.Task
  def run(args) do
    # Start application for database access
    Mix.Task.run("app.start")

    # Parse command-line arguments
    {opts, _remaining, invalid} =
      OptionParser.parse(
        args,
        switches: [
          model: :string,
          type: :string,
          ids: :string,
          limit: :integer,
          all: :boolean,
          force: :boolean,
          dry_run: :boolean,
          async: :boolean,
          multi_model: :boolean,
          no_multi_model: :boolean
        ],
        aliases: [
          m: :model,
          t: :type,
          i: :ids,
          l: :limit,
          a: :all,
          f: :force,
          d: :dry_run
        ]
      )

    # Handle invalid options
    if length(invalid) > 0 do
      Mix.shell().error("Invalid options: #{inspect(invalid)}")
      Mix.shell().error("Run `mix help ml.reprocess` for usage information")
      exit({:shutdown, 1})
    end

    # Validate and normalize options
    case validate_and_normalize_opts(opts) do
      {:ok, normalized_opts} ->
        print_header(normalized_opts)

        case Reprocessor.reprocess(normalized_opts) do
          {:ok, result} ->
            print_result(result, normalized_opts)
            :ok

          {:error, reason} ->
            Mix.shell().error("\n❌ Error: #{format_error(reason)}\n")
            exit({:shutdown, 1})
        end

      {:error, reason} ->
        Mix.shell().error("\n❌ Error: #{reason}\n")
        Mix.shell().error("Run `mix help ml.reprocess` for usage information")
        exit({:shutdown, 1})
    end
  end

  # Private functions

  defp validate_and_normalize_opts(opts) do
    with {:ok, model_opt} <- validate_model(opts[:model]),
         {:ok, type_opt} <- validate_type(opts[:type]),
         {:ok, ids_opt} <- validate_ids(opts[:ids]),
         {:ok, multi_model_opt} <- validate_multi_model(opts) do
      normalized =
        [
          model: model_opt,
          model_type: type_opt,
          content_ids: ids_opt,
          limit: opts[:limit] || 10,
          all: opts[:all] || false,
          force: opts[:force] || false,
          dry_run: opts[:dry_run] || false,
          async: opts[:async] || false,
          multi_model: multi_model_opt
        ]
        |> Enum.reject(fn {_k, v} -> is_nil(v) end)

      {:ok, normalized}
    end
  end

  defp validate_model(nil), do: {:ok, :all}
  defp validate_model("all"), do: {:ok, :all}

  defp validate_model(model) when is_binary(model) do
    if ModelRegistry.get_model(model) do
      {:ok, model}
    else
      available = ModelRegistry.list_models() |> Enum.map(& &1.id) |> Enum.join(", ")
      {:error, "Invalid model '#{model}'. Available: #{available}"}
    end
  end

  defp validate_type(nil), do: {:ok, :all}
  defp validate_type("sentiment"), do: {:ok, :sentiment}
  defp validate_type("ner"), do: {:ok, :ner}
  defp validate_type("all"), do: {:ok, :all}

  defp validate_type(type) do
    {:error, "Invalid type '#{type}'. Must be: sentiment, ner, or all"}
  end

  defp validate_ids(nil), do: {:ok, nil}

  defp validate_ids(ids_string) when is_binary(ids_string) do
    ids =
      ids_string
      |> String.split(",")
      |> Enum.map(&String.trim/1)
      |> Enum.map(&String.to_integer/1)

    {:ok, ids}
  rescue
    _ -> {:error, "Invalid IDs format. Must be comma-separated integers (e.g., 1,2,3)"}
  end

  defp validate_multi_model(opts) do
    cond do
      opts[:multi_model] == true -> {:ok, true}
      opts[:no_multi_model] == true -> {:ok, false}
      true -> {:ok, nil}  # Auto-detect
    end
  end

  defp print_header(opts) do
    Mix.shell().info("\n" <> String.duplicate("=", 80))
    Mix.shell().info("🔄 ML Reprocessing Pipeline")
    Mix.shell().info(String.duplicate("=", 80))

    # Show what will be processed
    model_desc =
      case opts[:model] do
        :all -> "All enabled models"
        model -> model
      end

    type_desc =
      case opts[:model_type] do
        :all -> "all types"
        type -> to_string(type)
      end

    content_desc =
      cond do
        opts[:content_ids] -> "#{length(opts[:content_ids])} specific content items"
        opts[:all] && opts[:force] -> "ALL content (including already classified)"
        opts[:all] -> "All unclassified content"
        true -> "Up to #{opts[:limit]} unclassified items"
      end

    Mix.shell().info("Model:   #{model_desc} (#{type_desc})")
    Mix.shell().info("Content: #{content_desc}")

    mode_desc = cond do
      opts[:dry_run] -> "DRY RUN (preview only)"
      opts[:async] -> "ASYNC (background jobs)"
      true -> "SYNC (immediate processing)"
    end
    Mix.shell().info("Mode:    #{mode_desc}")

    if opts[:multi_model] do
      Mix.shell().info("Multi:   Multi-model consensus enabled")
    end

    Mix.shell().info(String.duplicate("=", 80))
    Mix.shell().info("")
  end

  defp print_result(result, opts) do
    cond do
      opts[:dry_run] -> print_dry_run_result(result)
      opts[:async] || result[:async] -> print_async_result(result)
      true -> print_live_result(result)
    end
  end

  defp print_dry_run_result(result) do
    Mix.shell().info("\n📋 DRY RUN PREVIEW")
    Mix.shell().info(String.duplicate("-", 80))
    Mix.shell().info("Would process: #{result.total} content items")
    Mix.shell().info("Models: #{Enum.join(result.models_used, ", ")}")

    if result.total > 0 do
      Mix.shell().info("\nContent IDs (first 20):")

      result.content_ids
      |> Enum.take(20)
      |> Enum.each(fn id -> Mix.shell().info("  - #{id}") end)

      if result.total > 20 do
        Mix.shell().info("  ... and #{result.total - 20} more")
      end
    end

    Mix.shell().info("\n✅ Run without --dry-run to execute reprocessing\n")
  end

  defp print_live_result(result) do
    Mix.shell().info("\n" <> String.duplicate("=", 80))
    Mix.shell().info("📊 REPROCESSING SUMMARY")
    Mix.shell().info(String.duplicate("=", 80))
    Mix.shell().info("Total:     #{result.total}")
    Mix.shell().info("Processed: #{result.processed} ✅")
    Mix.shell().info("Skipped:   #{result.skipped}")
    Mix.shell().info("Failed:    #{result.failed} #{if result.failed > 0, do: "❌", else: ""}")
    Mix.shell().info("\nModels used: #{Enum.join(result.models_used, ", ")}")

    if result.failed > 0 do
      Mix.shell().info("\n⚠️  Some items failed to process. Check logs for details.")
    end

    Mix.shell().info("\n✅ Reprocessing complete!\n")
  end

  defp print_async_result(result) do
    Mix.shell().info("\n" <> String.duplicate("=", 80))
    Mix.shell().info("🚀 ASYNC JOBS ENQUEUED")
    Mix.shell().info(String.duplicate("=", 80))
    Mix.shell().info("Total items:     #{result.total}")
    Mix.shell().info("Jobs enqueued:   #{result.enqueued_jobs} ✅")
    Mix.shell().info("\nModels: #{Enum.join(result.models_used, ", ")}")

    Mix.shell().info("\n💡 Jobs are now processing in the background.")
    Mix.shell().info("   Monitor progress at: http://localhost:4000/admin/oban")
    Mix.shell().info("   Or use: mix ml.status")
    Mix.shell().info("\n✅ Jobs successfully enqueued!\n")
  end

  defp format_error({:invalid_model, model}), do: "Invalid model: #{model}"
  defp format_error(:no_models_selected), do: "No models selected for reprocessing"
  defp format_error(reason), do: inspect(reason)
end
