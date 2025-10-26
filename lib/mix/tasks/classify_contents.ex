defmodule Mix.Tasks.Classify.Contents do
  @moduledoc """
  Classifies unclassified content items using FinBERT.

  ## Usage

      # Classify first 10 unclassified items
      mix classify.contents --limit 10

      # Classify all unclassified items
      mix classify.contents --all

      # Classify specific content IDs
      mix classify.contents --ids 1,2,3,4,5

      # Show what would be classified without running
      mix classify.contents --limit 10 --dry-run

  ## Options

    * `--limit N` - Process first N unclassified items (default: 10)
    * `--all` - Process all unclassified items (overrides --limit)
    * `--ids 1,2,3` - Classify specific content IDs (comma-separated)
    * `--dry-run` - Show items that would be classified without processing

  ## Examples

      # Start small for testing
      mix classify.contents --limit 5

      # Process all after validation
      mix classify.contents --all
  """

  use Mix.Task

  alias VolfefeMachine.{Content, Intelligence, Repo}
  import Ecto.Query

  @shortdoc "Classifies content items using FinBERT sentiment analysis"

  @impl Mix.Task
  def run(args) do
    # Start application to get Repo and database access
    Mix.Task.run("app.start")

    # Parse command-line arguments
    {opts, _remaining, _invalid} =
      OptionParser.parse(
        args,
        switches: [limit: :integer, all: :boolean, ids: :string, dry_run: :boolean],
        aliases: [l: :limit, a: :all, i: :ids, d: :dry_run]
      )

    # Get content IDs to classify
    content_ids = get_content_ids(opts)

    if Enum.empty?(content_ids) do
      Mix.shell().info("\n✅ No content items to classify.\n")
    else
      Mix.shell().info("\n" <> String.duplicate("=", 80))
      Mix.shell().info("🔄 FinBERT Content Classification")
      Mix.shell().info(String.duplicate("=", 80))
      Mix.shell().info("Found #{length(content_ids)} content items to classify.\n")

      if opts[:dry_run] do
        dry_run(content_ids)
      else
        classify_batch(content_ids)
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
      content = Content.get_content(id)
      text_preview = String.slice(content.text || "", 0, 80)
      Mix.shell().info("  [#{id}] #{text_preview}...")
    end)

    Mix.shell().info("\n✅ Run without --dry-run to perform classification.\n")
  end

  defp classify_batch(content_ids) do
    total = length(content_ids)

    results =
      content_ids
      |> Enum.with_index(1)
      |> Enum.map(fn {content_id, index} ->
        classify_with_progress(content_id, index, total)
      end)

    # Print summary
    print_summary(results)
  end

  defp classify_with_progress(content_id, index, total) do
    Mix.shell().info("[#{index}/#{total}] Classifying content_id=#{content_id}...")

    start_time = System.monotonic_time(:millisecond)

    result = Intelligence.classify_content(content_id)

    elapsed = System.monotonic_time(:millisecond) - start_time

    case result do
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
        Mix.shell().error("  ❌ Error: #{reason}\n")
        {:error, content_id, reason}
    end
  end

  defp print_summary(results) do
    total = length(results)
    successful = Enum.count(results, &match?({:ok, _, _}, &1))
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
        |> Enum.filter(&match?({:ok, _, _}, &1))
        |> Enum.map(fn {:ok, _, classification} -> classification.sentiment end)
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
        |> Enum.filter(&match?({:ok, _, _}, &1))
        |> Enum.map(fn {:ok, _, classification} -> classification.confidence end)
        |> Enum.sum()
        |> Kernel./(successful)
        |> Float.round(4)

      Mix.shell().info("\n🎯 Average Confidence: #{avg_confidence}")
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
