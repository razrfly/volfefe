#!/usr/bin/env elixir

# Script to classify all unclassified content using FinBERT
# Run with: mix run priv/repo/scripts/classify_all_contents.exs

alias VolfefeMachine.{Content, Intelligence, Repo}
require Logger

IO.puts("\n" <> String.duplicate("=", 80))
IO.puts("🔄 Classifying Content with FinBERT")
IO.puts(String.duplicate("=", 80))

# Get all unclassified content
contents = Content.list_contents(classified: false)
total = length(contents)

IO.puts("\n📥 Found #{total} unclassified posts\n")

if total == 0 do
  IO.puts("✅ All content is already classified!")
  System.halt(0)
end

# Classify each content item
results =
  contents
  |> Enum.with_index(1)
  |> Enum.map(fn {content, index} ->
    IO.write("Processing #{index}/#{total}... ")

    case Intelligence.classify_content(content.id) do
      {:ok, classification} ->
        # Mark content as classified
        Content.mark_as_classified(content.id)
        IO.puts("✅ #{classification.sentiment} (#{Float.round(classification.confidence, 2)})")
        {:ok, classification}

      {:error, reason} ->
        IO.puts("❌ Error: #{inspect(reason)}")
        {:error, reason}
    end
  end)

# Analyze results
successes = Enum.count(results, fn {status, _} -> status == :ok end)
failures = Enum.count(results, fn {status, _} -> status == :error end)

IO.puts("\n" <> String.duplicate("=", 80))
IO.puts("📊 RESULTS")
IO.puts(String.duplicate("=", 80))
IO.puts("✅ Successfully classified: #{successes}")
IO.puts("❌ Failed: #{failures}")

if successes > 0 do
  # Get sentiment distribution
  classifications = Intelligence.list_classifications()

  sentiment_counts =
    classifications
    |> Enum.group_by(& &1.sentiment)
    |> Enum.map(fn {sentiment, items} -> {sentiment, length(items)} end)
    |> Enum.into(%{})

  IO.puts("\n📈 Sentiment Distribution:")
  total_db = length(classifications)

  for sentiment <- ["positive", "negative", "neutral"] do
    count = Map.get(sentiment_counts, sentiment, 0)
    pct = Float.round(count / total_db * 100, 1)
    IO.puts("  #{String.upcase(sentiment)}: #{count} (#{pct}%)")
  end

  # Show high confidence examples
  IO.puts("\n🎯 Sample High Confidence Classifications:")

  classifications
  |> Enum.filter(& &1.confidence > 0.9)
  |> Enum.take(5)
  |> Enum.each(fn classification ->
    content = Repo.preload(classification, :content).content
    text_preview =
      case content.text do
        nil -> "(no text)"
        text -> String.slice(text, 0..100) <> "..."
      end

    IO.puts("\n  #{String.upcase(classification.sentiment)} (#{Float.round(classification.confidence, 2)})")
    IO.puts("  \"#{text_preview}\"")
  end)
end

IO.puts("\n✅ Classification complete!\n")
