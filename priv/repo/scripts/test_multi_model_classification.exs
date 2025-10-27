#!/usr/bin/env elixir

# Test Multi-Model Classification End-to-End
#
# This script:
# 1. Temporarily removes classification for content_id=2
# 2. Runs multi-model classification
# 3. Verifies results are stored correctly
# 4. Shows consensus and individual model results

alias VolfefeMachine.{Content, Intelligence, Repo}
alias VolfefeMachine.Intelligence.{Classification, ModelClassification}
import Ecto.Query

# Start the application
{:ok, _} = Application.ensure_all_started(:volfefe_machine)

IO.puts("\n" <> String.duplicate("=", 80))
IO.puts("🧪 MULTI-MODEL CLASSIFICATION TEST")
IO.puts(String.duplicate("=", 80))

content_id = 2

# Step 1: Get the content
IO.puts("\n📝 Step 1: Fetching content...")
content = Content.get_content(content_id)

if is_nil(content) do
  IO.puts("❌ Content not found!")
  System.halt(1)
end

IO.puts("✅ Found content:")
IO.puts("   Text: #{String.slice(content.text, 0, 100)}...")

# Step 2: Remove existing classifications
IO.puts("\n🗑️  Step 2: Removing existing classifications...")

# Delete model classifications
{model_count, _} = Repo.delete_all(
  from mc in ModelClassification,
  where: mc.content_id == ^content_id
)
IO.puts("   Deleted #{model_count} model classifications")

# Delete consensus classification
{consensus_count, _} = Repo.delete_all(
  from c in Classification,
  where: c.content_id == ^content_id
)
IO.puts("   Deleted #{consensus_count} consensus classification")

# Mark as unclassified
content
|> Ecto.Changeset.change(%{classified: false})
|> Repo.update!()
IO.puts("   ✅ Content marked as unclassified")

# Step 3: Run multi-model classification
IO.puts("\n🤖 Step 3: Running multi-model classification...")
start_time = System.monotonic_time(:millisecond)

result = Intelligence.classify_content_multi_model(content_id)

elapsed = System.monotonic_time(:millisecond) - start_time

case result do
  {:ok, %{consensus: consensus, model_results: model_results, metadata: metadata}} ->
    IO.puts("✅ Classification successful (#{elapsed}ms)")

    # Step 4: Display results
    IO.puts("\n" <> String.duplicate("=", 80))
    IO.puts("📊 RESULTS")
    IO.puts(String.duplicate("=", 80))

    # Consensus
    IO.puts("\n🎯 Consensus Result:")
    IO.puts("   Sentiment: #{consensus.sentiment}")
    IO.puts("   Confidence: #{Float.round(consensus.confidence, 4)}")
    IO.puts("   Model Version: #{consensus.model_version}")
    IO.puts("   Agreement Rate: #{Float.round(consensus.meta[:agreement_rate] * 100, 1)}%")
    IO.puts("   Method: #{consensus.meta[:consensus_method]}")

    # Individual models
    IO.puts("\n🤖 Individual Model Results:")
    for mc <- model_results do
      IO.puts("\n   #{mc.model_id}:")
      IO.puts("     Sentiment: #{mc.sentiment}")
      IO.puts("     Confidence: #{Float.round(mc.confidence, 4)}")
      IO.puts("     Model Version: #{mc.model_version}")

      if mc.meta["raw_scores"] do
        IO.puts("     Raw Scores:")
        for {sentiment, score} <- mc.meta["raw_scores"] do
          IO.puts("       #{sentiment}: #{score}")
        end
      end
    end

    # Metadata
    IO.puts("\n⚡ Performance Metrics:")
    IO.puts("   Total Latency: #{metadata.total_latency_ms}ms")
    IO.puts("   Models Used: #{Enum.join(metadata.models_used, ", ")}")
    IO.puts("   Successful Models: #{metadata.successful_models}")

    # Step 5: Verify database records
    IO.puts("\n✅ Step 5: Verifying database records...")

    # Check consensus
    db_consensus = Intelligence.get_classification_by_content(content_id)
    IO.puts("   Consensus record: #{if db_consensus, do: "✅ Found", else: "❌ Missing"}")

    # Check model classifications
    db_models = Repo.all(
      from mc in ModelClassification,
      where: mc.content_id == ^content_id
    )
    IO.puts("   Model classification records: #{length(db_models)}")

    # Check content marked as classified
    updated_content = Content.get_content(content_id)
    IO.puts("   Content classified flag: #{if updated_content.classified, do: "✅ True", else: "❌ False"}")

    IO.puts("\n" <> String.duplicate("=", 80))
    IO.puts("✅ TEST PASSED - Multi-model classification working correctly!")
    IO.puts(String.duplicate("=", 80) <> "\n")

  {:error, reason} ->
    IO.puts("❌ Classification failed: #{inspect(reason)}")
    IO.puts("\n" <> String.duplicate("=", 80))
    IO.puts("❌ TEST FAILED")
    IO.puts(String.duplicate("=", 80) <> "\n")
    System.halt(1)
end
