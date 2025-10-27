defmodule Mix.Tasks.Classify.Contents do
  @moduledoc """
  Classifies unclassified content items using sentiment analysis models.

  ## Usage

      # Classify first 10 unclassified items (single model - FinBERT)
      mix classify.contents --limit 10

      # Classify using ALL models (multi-model with consensus)
      mix classify.contents --limit 10 --multi-model

      # Classify all unclassified items with multi-model
      mix classify.contents --all --multi-model

      # Classify specific content IDs
      mix classify.contents --ids 1,2,3,4,5

      # Show what would be classified without running
      mix classify.contents --limit 10 --dry-run

  ## Options

    * `--limit N` - Process first N unclassified items (default: 10)
    * `--all` - Process all unclassified items (overrides --limit)
    * `--ids 1,2,3` - Classify specific content IDs (comma-separated)
    * `--multi-model` - Use all configured models with weighted consensus (recommended)
    * `--dry-run` - Show items that would be classified without processing

  ## Examples

      # Start small for testing with single model
      mix classify.contents --limit 5

      # Test multi-model approach
      mix classify.contents --limit 5 --multi-model

      # Process all with multi-model after validation
      mix classify.contents --all --multi-model
  """

  use Mix.Task

  alias VolfefeMachine.{Content, Intelligence, Repo}
  import Ecto.Query

  @shortdoc "Classifies content items using sentiment analysis (single or multi-model)"

  @impl Mix.Task
  def run(args) do
    # Start application to get Repo and database access
    Mix.Task.run("app.start")

    # Parse command-line arguments
    {opts, _remaining, _invalid} =
      OptionParser.parse(
        args,
        switches: [limit: :integer, all: :boolean, ids: :string, dry_run: :boolean, multi_model: :boolean],
        aliases: [l: :limit, a: :all, i: :ids, d: :dry_run, m: :multi_model]
      )

    # Get content IDs to classify
    content_ids = get_content_ids(opts)

    if Enum.empty?(content_ids) do
      Mix.shell().info("\n✅ No content items to classify.\n")
    else
      mode_name = if opts[:multi_model], do: "Multi-Model (Consensus)", else: "Single Model (FinBERT)"

      Mix.shell().info("\n" <> String.duplicate("=", 80))
      Mix.shell().info("🔄 Sentiment Classification - #{mode_name}")
      Mix.shell().info(String.duplicate("=", 80))
      Mix.shell().info("Found #{length(content_ids)} content items to classify.\n")

      if opts[:dry_run] do
        dry_run(content_ids)
      else
        classify_batch(content_ids, opts[:multi_model] || false)
      end
    end
  end

  defp get_content_ids(opts) do
    cond do
      # Specific IDs provided
      opts[:ids] ->
        opts[:ids]
        |> String.split(",")
        |> Enum.map(&String.trim/1)
        |> Enum.map(&String.to_integer/1)

      # All unclassified
      opts[:all] ->
        query_unclassified()
        |> Repo.all()

      # Limited number (default: 10)
      true ->
        limit = opts[:limit] || 10

        query_unclassified()
        |> limit(^limit)
        |> Repo.all()
    end
  end

  defp query_unclassified do
    from c in Content.Content,
      left_join: cl in assoc(c, :classification),
      where: is_nil(cl.id) and not is_nil(c.text) and c.text != "",
      select: c.id,
      order_by: [asc: c.id]
  end

  defp dry_run(content_ids) do
    Mix.shell().info("DRY RUN - Would classify these content IDs:\n")

    content_ids
    |> Enum.each(fn id ->
      case Content.get_content(id) do
        nil ->
          Mix.shell().info("  [#{id}] (missing)")

        content ->
          text_preview = String.slice(content.text || "", 0, 80)
          Mix.shell().info("  [#{id}] #{text_preview}...")
      end
    end)

    Mix.shell().info("\n✅ Run without --dry-run to perform classification.\n")
  end

  defp classify_batch(content_ids, multi_model) do
    total = length(content_ids)

    results =
      content_ids
      |> Enum.with_index(1)
      |> Enum.map(fn {content_id, index} ->
        classify_with_progress(content_id, index, total, multi_model)
      end)

    # Print summary
    print_summary(results, multi_model)
  end

  defp classify_with_progress(content_id, index, total, multi_model) do
    Mix.shell().info("[#{index}/#{total}] Classifying content_id=#{content_id}...")

    start_time = System.monotonic_time(:millisecond)

    result = if multi_model do
      Intelligence.classify_content_multi_model(content_id)
    else
      Intelligence.classify_content(content_id)
    end

    elapsed = System.monotonic_time(:millisecond) - start_time

    case result do
      # Multi-model result
      {:ok, %{consensus: classification, model_results: model_results, metadata: metadata}} ->
        # Mark content as classified
        Content.mark_as_classified(content_id)

        sentiment_emoji =
          case classification.sentiment do
            "positive" -> "📈"
            "negative" -> "📉"
            "neutral" -> "➖"
          end

        # Show consensus + model agreement
        agreement = classification.meta["agreement_rate"]
        agreement_pct = Float.round(agreement * 100, 0)

        Mix.shell().info(
          "  ✅ #{sentiment_emoji} #{classification.sentiment} (#{Float.round(classification.confidence, 2)}) | Agreement: #{agreement_pct}% | #{length(model_results)} models - #{elapsed}ms\n"
        )

        {:ok, content_id, classification, model_results}

      # Single-model result
      {:ok, classification} ->
        # Mark content as classified
        Content.mark_as_classified(content_id)

        sentiment_emoji =
          case classification.sentiment do
            "positive" -> "📈"
            "negative" -> "📉"
            "neutral" -> "➖"
          end

        Mix.shell().info(
          "  ✅ #{sentiment_emoji} #{classification.sentiment} (#{Float.round(classification.confidence, 2)}) - #{elapsed}ms\n"
        )

        {:ok, content_id, classification}

      {:error, reason} ->
        Mix.shell().error("  ❌ Error: #{inspect(reason)}\n")
        {:error, content_id, reason}
    end
  end

  defp print_summary(results, multi_model) do
    total = length(results)

    # Handle both single-model and multi-model result formats
    successful = if multi_model do
      Enum.count(results, &match?({:ok, _, _, _}, &1))
    else
      Enum.count(results, &match?({:ok, _, _}, &1))
    end

    failed = total - successful

    Mix.shell().info(String.duplicate("=", 80))
    Mix.shell().info("📊 CLASSIFICATION SUMMARY")
    Mix.shell().info(String.duplicate("=", 80))
    Mix.shell().info("Total:      #{total}")
    Mix.shell().info("Successful: #{successful}")
    Mix.shell().info("Failed:     #{failed}")

    if successful > 0 do
      # Sentiment distribution
      sentiments =
        results
        |> Enum.filter(fn result ->
          if multi_model do
            match?({:ok, _, _, _}, result)
          else
            match?({:ok, _, _}, result)
          end
        end)
        |> Enum.map(fn result ->
          if multi_model do
            {:ok, _, classification, _} = result
            classification.sentiment
          else
            {:ok, _, classification} = result
            classification.sentiment
          end
        end)
        |> Enum.frequencies()

      Mix.shell().info("\n📈 Sentiment Distribution:")

      for sentiment <- ["positive", "negative", "neutral"] do
        count = Map.get(sentiments, sentiment, 0)
        pct = if successful > 0, do: Float.round(count / successful * 100, 1), else: 0.0
        Mix.shell().info("  #{String.upcase(sentiment)}: #{count} (#{pct}%)")
      end

      # Average confidence
      avg_confidence =
        results
        |> Enum.filter(fn result ->
          if multi_model do
            match?({:ok, _, _, _}, result)
          else
            match?({:ok, _, _}, result)
          end
        end)
        |> Enum.map(fn result ->
          if multi_model do
            {:ok, _, classification, _} = result
            classification.confidence
          else
            {:ok, _, classification} = result
            classification.confidence
          end
        end)
        |> Enum.sum()
        |> Kernel./(successful)
        |> Float.round(4)

      Mix.shell().info("\n🎯 Average Confidence: #{avg_confidence}")

      # Multi-model specific stats
      if multi_model do
        avg_agreement =
          results
          |> Enum.filter(&match?({:ok, _, _, _}, &1))
          |> Enum.map(fn {:ok, _, classification, _} ->
            classification.meta["agreement_rate"]
          end)
          |> Enum.sum()
          |> Kernel./(successful)
          |> Kernel.*(100)
          |> Float.round(1)

        Mix.shell().info("🤝 Average Agreement: #{avg_agreement}%")
      end
    end

    if failed > 0 do
      Mix.shell().info("\n❌ Failed Content IDs:")

      results
      |> Enum.filter(&match?({:error, _, _}, &1))
      |> Enum.each(fn {:error, content_id, reason} ->
        Mix.shell().info("  [#{content_id}] #{reason}")
      end)
    end

    Mix.shell().info("\n✅ Classification complete!\n")
  end
end
