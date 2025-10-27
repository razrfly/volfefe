#!/usr/bin/env elixir
#
# Test script for model_classifications schema
# Tests creating, reading, and querying model classification records
#
# Usage: mix run priv/repo/scripts/test_model_classifications_schema.exs

alias VolfefeMachine.{Repo, Content}
alias VolfefeMachine.Intelligence.ModelClassification
import Ecto.Query

IO.puts("\n================================================================================")
IO.puts("Testing model_classifications Schema")
IO.puts("================================================================================\n")

# Step 1: Get or create a test content
IO.puts("Step 1: Getting test content...")

content = Content.list_contents() |> List.first()

if content do
  IO.puts("  ✅ Using existing content ID: #{content.id}")
  IO.puts("  Text preview: #{String.slice(content.text || "", 0, 80)}...")
else
  IO.puts("  ❌ No content found in database")
  IO.puts("  Please run: mix run priv/repo/scripts/truthsocial_sample_import.exs")
  System.halt(1)
end

# Step 2: Create sample model classifications
IO.puts("\nStep 2: Creating sample model classifications...")

sample_classifications = [
  %{
    content_id: content.id,
    model_id: "distilbert",
    model_version: "distilbert-base-uncased-finetuned-sst-2-english",
    sentiment: "negative",
    confidence: 0.9757,
    meta: %{
      "raw_scores" => %{
        "positive" => 0.0243,
        "negative" => 0.9757
      },
      "processing" => %{
        "latency_ms" => 53,
        "timestamp" => "2025-10-26T18:30:00Z"
      },
      "text_info" => %{
        "char_count" => 150,
        "word_count" => 25
      },
      "quality" => %{
        "score_margin" => 0.9514,
        "entropy" => 0.15,
        "flags" => ["high_confidence", "clear_winner"]
      }
    }
  },
  %{
    content_id: content.id,
    model_id: "twitter_roberta",
    model_version: "cardiffnlp/twitter-roberta-base-sentiment-latest",
    sentiment: "negative",
    confidence: 0.7525,
    meta: %{
      "raw_scores" => %{
        "positive" => 0.12,
        "neutral" => 0.1275,
        "negative" => 0.7525
      },
      "processing" => %{
        "latency_ms" => 90,
        "timestamp" => "2025-10-26T18:30:00Z"
      }
    }
  },
  %{
    content_id: content.id,
    model_id: "finbert",
    model_version: "yiyanghkust/finbert-tone",
    sentiment: "neutral",
    confidence: 0.9982,
    meta: %{
      "raw_scores" => %{
        "positive" => 0.0009,
        "neutral" => 0.9982,
        "negative" => 0.0009
      },
      "processing" => %{
        "latency_ms" => 2156,
        "timestamp" => "2025-10-26T18:30:00Z"
      }
    }
  }
]

results = Enum.map(sample_classifications, fn attrs ->
  case ModelClassification.changeset(%ModelClassification{}, attrs) |> Repo.insert() do
    {:ok, mc} ->
      IO.puts("  ✅ Created: #{mc.model_id} -> #{mc.sentiment} (#{Float.round(mc.confidence * 100, 2)}%)")
      {:ok, mc}
    {:error, changeset} ->
      IO.puts("  ❌ Error creating #{attrs.model_id}: #{inspect(changeset.errors)}")
      {:error, changeset}
  end
end)

successful = Enum.count(results, fn {status, _} -> status == :ok end)
IO.puts("\n  Created #{successful}/#{length(sample_classifications)} model classifications")

# Step 3: Query the model classifications
IO.puts("\nStep 3: Querying model classifications...")

# Query by content
mc_for_content = ModelClassification
                 |> where([mc], mc.content_id == ^content.id)
                 |> Repo.all()

IO.puts("\n  Model classifications for content #{content.id}:")
for mc <- mc_for_content do
  IO.puts("    - #{mc.model_id}: #{mc.sentiment} (#{Float.round(mc.confidence * 100, 2)}%)")
end

# Query by sentiment
negative_mcs = ModelClassification
               |> where([mc], mc.sentiment == "negative")
               |> Repo.all()

IO.puts("\n  Total negative classifications: #{length(negative_mcs)}")

# Query by model
distilbert_mcs = ModelClassification
                 |> where([mc], mc.model_id == "distilbert")
                 |> Repo.all()

IO.puts("  Total DistilBERT classifications: #{length(distilbert_mcs)}")

# Step 4: Test preloading with content
IO.puts("\nStep 4: Testing associations...")

mc_with_content = ModelClassification
                  |> where([mc], mc.content_id == ^content.id)
                  |> preload(:content)
                  |> limit(1)
                  |> Repo.one()

if mc_with_content do
  IO.puts("  ✅ Preload works: #{mc_with_content.model_id} belongs to content #{mc_with_content.content.id}")
else
  IO.puts("  ❌ Preload failed")
end

# Test reverse association (content has_many model_classifications)
content_with_mcs = Content.get_content(content.id)
                   |> Repo.preload(:model_classifications)

if content_with_mcs.model_classifications do
  IO.puts("  ✅ Reverse association works: content #{content.id} has #{length(content_with_mcs.model_classifications)} model classifications")
else
  IO.puts("  ❌ Reverse association failed")
end

# Step 5: Test unique constraint
IO.puts("\nStep 5: Testing unique constraint (content_id + model_id + model_version)...")

duplicate = %{
  content_id: content.id,
  model_id: "distilbert",
  model_version: "distilbert-base-uncased-finetuned-sst-2-english",
  sentiment: "positive",
  confidence: 0.99,
  meta: %{}
}

case ModelClassification.changeset(%ModelClassification{}, duplicate) |> Repo.insert() do
  {:ok, _} ->
    IO.puts("  ❌ FAIL: Unique constraint did not prevent duplicate")
  {:error, changeset} ->
    if Keyword.has_key?(changeset.errors, :content_id) or
       changeset.errors
       |> Enum.any?(fn {_field, {msg, _opts}} -> String.contains?(msg, "already been taken") end) do
      IO.puts("  ✅ PASS: Unique constraint prevented duplicate")
    else
      IO.puts("  ⚠️  Different error: #{inspect(changeset.errors)}")
    end
end

# Step 6: Summary
IO.puts("\n================================================================================")
IO.puts("Test Summary")
IO.puts("================================================================================\n")

total_mcs = Repo.aggregate(ModelClassification, :count, :id)
IO.puts("  Total model_classifications in database: #{total_mcs}")

by_model = ModelClassification
           |> group_by([mc], mc.model_id)
           |> select([mc], {mc.model_id, count(mc.id)})
           |> Repo.all()
           |> Enum.into(%{})

IO.puts("\n  By model:")
for {model_id, count} <- by_model do
  IO.puts("    #{model_id}: #{count}")
end

by_sentiment = ModelClassification
               |> group_by([mc], mc.sentiment)
               |> select([mc], {mc.sentiment, count(mc.id)})
               |> Repo.all()
               |> Enum.into(%{})

IO.puts("\n  By sentiment:")
for {sentiment, count} <- by_sentiment do
  IO.puts("    #{sentiment}: #{count}")
end

IO.puts("\n✅ Schema test complete!")
IO.puts("\nTo clean up test data, run:")
IO.puts("  Repo.delete_all(from mc in ModelClassification, where: mc.content_id == #{content.id})")
IO.puts("")
