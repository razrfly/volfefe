#!/usr/bin/env elixir

# Import classifications from classification_results.json into database
# Run with: mix run priv/repo/scripts/import_classifications_from_json.exs

alias VolfefeMachine.{Content, Intelligence, Repo}
require Logger

IO.puts("\n" <> String.duplicate("=", 80))
IO.puts("📥 Importing Classifications from JSON")
IO.puts(String.duplicate("=", 80))

# Read JSON file
json_path = "classification_results.json"

unless File.exists?(json_path) do
  IO.puts("❌ Error: #{json_path} not found")
  System.halt(1)
end

{:ok, json} = File.read(json_path)
{:ok, data} = Jason.decode(json)

results = data["results"]
total = length(results)

IO.puts("\n📊 Found #{total} classifications in JSON file")
IO.puts("Starting import...\n")

# Import each classification
imported =
  results
  |> Enum.with_index(1)
  |> Enum.reduce({0, 0, 0}, fn {result, index}, {success, skipped, failed} ->
    external_id = result["external_id"]

    # Find content by external_id
    content =
      Repo.one(
        from c in VolfefeMachine.Content.Content,
          where: c.external_id == ^external_id
      )

    cond do
      is_nil(content) ->
        IO.puts("#{index}/#{total} ⚠️  Skipped: Content not found (#{external_id})")
        {success, skipped + 1, failed}

      # Check if classification already exists
      Intelligence.get_classification_by_content(content.id) ->
        IO.puts("#{index}/#{total} ⏭️  Skipped: Already classified (#{external_id})")
        {success, skipped + 1, failed}

      true ->
        # Create classification
        attrs = %{
          content_id: content.id,
          sentiment: result["sentiment"],
          confidence: result["confidence"],
          model_version: "finbert-tone-v1.0",
          meta: %{
            "raw_scores" => %{
              "positive" => result["confidence"],
              "negative" => 0.0,
              "neutral" => 0.0
            },
            "imported_from_json" => true,
            "original_url" => result["url"]
          }
        }

        case Intelligence.create_classification(attrs) do
          {:ok, _classification} ->
            Content.mark_as_classified(content.id)
            sentiment_emoji =
              case result["sentiment"] do
                "positive" -> "📈"
                "negative" -> "📉"
                "neutral" -> "➖"
              end

            IO.puts(
              "#{index}/#{total} ✅ #{sentiment_emoji} #{result["sentiment"]} (#{result["confidence"]})"
            )

            {success + 1, skipped, failed}

          {:error, changeset} ->
            IO.puts("#{index}/#{total} ❌ Failed: #{inspect(changeset.errors)}")
            {success, skipped, failed + 1}
        end
    end
  end)

{success_count, skipped_count, failed_count} = imported

IO.puts("\n" <> String.duplicate("=", 80))
IO.puts("📊 IMPORT RESULTS")
IO.puts(String.duplicate("=", 80))
IO.puts("✅ Successfully imported: #{success_count}")
IO.puts("⏭️  Skipped: #{skipped_count}")
IO.puts("❌ Failed: #{failed_count}")

# Show sentiment distribution
if success_count > 0 do
  classifications = Intelligence.list_classifications()

  sentiment_counts =
    classifications
    |> Enum.group_by(& &1.sentiment)
    |> Enum.map(fn {sentiment, items} -> {sentiment, length(items)} end)
    |> Enum.into(%{})

  total_classified = length(classifications)

  IO.puts("\n📈 Database Sentiment Distribution:")

  for sentiment <- ["positive", "negative", "neutral"] do
    count = Map.get(sentiment_counts, sentiment, 0)
    pct = Float.round(count / total_classified * 100, 1)
    IO.puts("  #{String.upcase(sentiment)}: #{count} (#{pct}%)")
  end

  # Show average confidence
  avg_confidence =
    classifications
    |> Enum.map(& &1.confidence)
    |> Enum.sum()
    |> Kernel./(total_classified)
    |> Float.round(4)

  IO.puts("\n🎯 Average Confidence: #{avg_confidence}")
end

IO.puts("\n✅ Import complete!\n")
