#!/usr/bin/env elixir

# Data Migration for Multi-Model Architecture
#
# This script:
# 1. Analyzes current state (existing classifications)
# 2. Backfills existing classifications as FinBERT model results
# 3. Re-runs ALL content through multi-model classification
# 4. Validates consensus calculations
# 5. Compares before/after distributions

alias VolfefeMachine.{Content, Intelligence, Repo}
alias VolfefeMachine.Intelligence.{Classification, ModelClassification}
import Ecto.Query

# Start the application
{:ok, _} = Application.ensure_all_started(:volfefe_machine)

IO.puts("\n" <> String.duplicate("=", 80))
IO.puts("📦 MULTI-MODEL ARCHITECTURE MIGRATION")
IO.puts(String.duplicate("=", 80))

# ============================================================================
# PHASE 1: Analyze Current State
# ============================================================================

IO.puts("\n" <> String.duplicate("-", 80))
IO.puts("📊 PHASE 1: Current State Analysis")
IO.puts(String.duplicate("-", 80))

# Get all content
total_content = Repo.aggregate(Content.Content, :count, :id)
IO.puts("\n📝 Content:")
IO.puts("   Total content items: #{total_content}")

# Get all classifications (old single-model)
total_classifications = Repo.aggregate(Classification, :count, :id)
IO.puts("\n🎯 Classifications:")
IO.puts("   Total classifications: #{total_classifications}")

# Check for consensus classifications
consensus_count = Repo.one(
  from c in Classification,
  where: c.model_version == "consensus_v1.0",
  select: count(c.id)
)
IO.puts("   Consensus classifications: #{consensus_count}")

# Check for old FinBERT classifications
finbert_count = Repo.one(
  from c in Classification,
  where: c.model_version != "consensus_v1.0",
  select: count(c.id)
)
IO.puts("   FinBERT-only classifications: #{finbert_count}")

# Get sentiment distribution (before)
sentiments_before = Intelligence.sentiment_distribution()
IO.puts("\n📈 Current Sentiment Distribution:")
for sentiment <- ["positive", "negative", "neutral"] do
  count = Map.get(sentiments_before, sentiment, 0)
  pct = if total_classifications > 0, do: Float.round(count / total_classifications * 100, 1), else: 0.0
  IO.puts("   #{String.upcase(sentiment)}: #{count} (#{pct}%)")
end

# Check model classifications
total_model_classifications = Repo.aggregate(ModelClassification, :count, :id)
IO.puts("\n🤖 Model Classifications:")
IO.puts("   Total model classification records: #{total_model_classifications}")

# ============================================================================
# PHASE 2: Backfill FinBERT Results
# ============================================================================

IO.puts("\n" <> String.duplicate("-", 80))
IO.puts("🔄 PHASE 2: Backfilling FinBERT Results")
IO.puts(String.duplicate("-", 80))

if finbert_count > 0 do
  IO.puts("\n📝 Found #{finbert_count} FinBERT-only classifications to backfill...")

  # Get all old FinBERT classifications
  old_classifications = Repo.all(
    from c in Classification,
    where: c.model_version != "consensus_v1.0",
    order_by: [asc: c.id]
  )

  backfilled = 0
  skipped = 0

  for classification <- old_classifications do
    # Check if already has model_classification
    existing = Repo.one(
      from mc in ModelClassification,
      where: mc.content_id == ^classification.content_id and mc.model_id == "finbert"
    )

    if existing do
      skipped = skipped + 1
    else
      # Create model_classification from existing classification
      attrs = %{
        content_id: classification.content_id,
        model_id: "finbert",
        model_version: classification.model_version,
        sentiment: classification.sentiment,
        confidence: classification.confidence,
        meta: classification.meta
      }

      case ModelClassification.changeset(%ModelClassification{}, attrs) |> Repo.insert() do
        {:ok, _mc} ->
          backfilled = backfilled + 1
          if rem(backfilled, 10) == 0 do
            IO.write(".")
          end
        {:error, changeset} ->
          IO.puts("\n   ⚠️  Failed to backfill content_id=#{classification.content_id}: #{inspect(changeset.errors)}")
      end
    end
  end

  IO.puts("\n✅ Backfilled #{backfilled} FinBERT results (#{skipped} already existed)")
else
  IO.puts("\n✅ No backfill needed - all classifications are already multi-model consensus")
end

# ============================================================================
# PHASE 3: Re-classify All Content with Multi-Model
# ============================================================================

IO.puts("\n" <> String.duplicate("-", 80))
IO.puts("🤖 PHASE 3: Multi-Model Re-classification")
IO.puts(String.duplicate("-", 80))

IO.puts("\n⚠️  This will:")
IO.puts("   1. Mark ALL content as unclassified")
IO.puts("   2. Delete ALL existing model_classifications")
IO.puts("   3. Delete ALL existing consensus classifications")
IO.puts("   4. Re-run multi-model classification on ALL content")
IO.puts("")

IO.puts("   This ensures:")
IO.puts("   ✓ All content has results from all 3 models")
IO.puts("   ✓ All consensus calculations are fresh and consistent")
IO.puts("   ✓ Complete data for future analysis")
IO.puts("")

IO.write("   Continue? (yes/no): ")
response = IO.gets("") |> String.trim() |> String.downcase()

if response == "yes" do
  IO.puts("\n🗑️  Step 1: Clearing existing data...")

  # Delete all model classifications
  {model_deleted, _} = Repo.delete_all(ModelClassification)
  IO.puts("   Deleted #{model_deleted} model classification records")

  # Delete all classifications
  {class_deleted, _} = Repo.delete_all(Classification)
  IO.puts("   Deleted #{class_deleted} classification records")

  # Mark all content as unclassified
  {content_updated, _} = Repo.update_all(Content.Content, set: [classified: false])
  IO.puts("   Marked #{content_updated} content items as unclassified")

  IO.puts("\n🚀 Step 2: Running multi-model classification...")
  IO.puts("   This will take several minutes for all content...")
  IO.puts("")

  # Get all content IDs with text
  content_ids = Repo.all(
    from c in Content.Content,
    where: not is_nil(c.text) and c.text != "",
    select: c.id,
    order_by: [asc: c.id]
  )

  total = length(content_ids)
  IO.puts("   Processing #{total} content items...\n")

  start_time = System.monotonic_time(:millisecond)

  results = content_ids
  |> Enum.with_index(1)
  |> Enum.map(fn {content_id, index} ->
    if rem(index, 10) == 0 do
      IO.write("\r   Progress: #{index}/#{total} (#{Float.round(index / total * 100, 1)}%)")
    end

    case Intelligence.classify_content_multi_model(content_id) do
      {:ok, _result} ->
        Content.mark_as_classified(content_id)
        {:ok, content_id}
      {:error, reason} ->
        {:error, content_id, reason}
    end
  end)

  elapsed = System.monotonic_time(:millisecond) - start_time
  elapsed_sec = div(elapsed, 1000)

  IO.puts("\r   Progress: #{total}/#{total} (100.0%)                                          ")
  IO.puts("\n✅ Classification complete in #{elapsed_sec}s")

  # Count successes and failures
  successful = Enum.count(results, &match?({:ok, _}, &1))
  failed = total - successful

  IO.puts("   Successful: #{successful}")
  IO.puts("   Failed: #{failed}")

  if failed > 0 do
    IO.puts("\n   ❌ Failed content IDs:")
    results
    |> Enum.filter(&match?({:error, _, _}, &1))
    |> Enum.each(fn {:error, content_id, reason} ->
      IO.puts("      [#{content_id}] #{inspect(reason)}")
    end)
  end

  # ============================================================================
  # PHASE 4: Validation
  # ============================================================================

  IO.puts("\n" <> String.duplicate("-", 80))
  IO.puts("✅ PHASE 4: Validation & Analysis")
  IO.puts(String.duplicate("-", 80))

  # Verify all content has classifications
  classified_count = Repo.one(
    from c in Content.Content,
    where: c.classified == true,
    select: count(c.id)
  )
  IO.puts("\n📊 Classification Coverage:")
  IO.puts("   Classified: #{classified_count}/#{total} (#{Float.round(classified_count / total * 100, 1)}%)")

  # Verify model classifications
  total_model_class = Repo.aggregate(ModelClassification, :count, :id)
  expected_model_class = successful * 3  # 3 models per content
  IO.puts("\n🤖 Model Classifications:")
  IO.puts("   Total: #{total_model_class}")
  IO.puts("   Expected: #{expected_model_class} (#{successful} items × 3 models)")
  IO.puts("   Match: #{if total_model_class == expected_model_class, do: "✅", else: "⚠️"}")

  # Show model breakdown
  model_breakdown = Repo.all(
    from mc in ModelClassification,
    group_by: mc.model_id,
    select: {mc.model_id, count(mc.id)}
  )
  |> Enum.into(%{})

  IO.puts("\n   By Model:")
  for model_id <- ["distilbert", "twitter_roberta", "finbert"] do
    count = Map.get(model_breakdown, model_id, 0)
    IO.puts("      #{model_id}: #{count}")
  end

  # Verify consensus classifications
  total_consensus = Repo.one(
    from c in Classification,
    where: c.model_version == "consensus_v1.0",
    select: count(c.id)
  )
  IO.puts("\n🎯 Consensus Classifications:")
  IO.puts("   Total: #{total_consensus}")
  IO.puts("   Expected: #{successful}")
  IO.puts("   Match: #{if total_consensus == successful, do: "✅", else: "⚠️"}")

  # New sentiment distribution
  sentiments_after = Intelligence.sentiment_distribution()
  IO.puts("\n📈 New Sentiment Distribution:")
  for sentiment <- ["positive", "negative", "neutral"] do
    count = Map.get(sentiments_after, sentiment, 0)
    pct = if total_consensus > 0, do: Float.round(count / total_consensus * 100, 1), else: 0.0
    IO.puts("   #{String.upcase(sentiment)}: #{count} (#{pct}%)")
  end

  # Compare before/after
  IO.puts("\n📊 Distribution Change:")
  for sentiment <- ["positive", "negative", "neutral"] do
    before_count = Map.get(sentiments_before, sentiment, 0)
    after_count = Map.get(sentiments_after, sentiment, 0)
    before_pct = if total_classifications > 0, do: Float.round(before_count / total_classifications * 100, 1), else: 0.0
    after_pct = if total_consensus > 0, do: Float.round(after_count / total_consensus * 100, 1), else: 0.0
    diff = after_pct - before_pct
    diff_str = if diff > 0, do: "+#{diff}", else: "#{diff}"
    IO.puts("   #{String.upcase(sentiment)}: #{before_pct}% → #{after_pct}% (#{diff_str}%)")
  end

  # Agreement rate analysis
  avg_agreement = Repo.one(
    from c in Classification,
    where: c.model_version == "consensus_v1.0",
    select: avg(fragment("(meta->>'agreement_rate')::float"))
  )

  if avg_agreement do
    IO.puts("\n🤝 Consensus Quality:")
    IO.puts("   Average Agreement: #{Float.round(avg_agreement * 100, 1)}%")

    # Low agreement cases
    low_agreement = Repo.one(
      from c in Classification,
      where: c.model_version == "consensus_v1.0" and fragment("(meta->>'agreement_rate')::float < 0.5"),
      select: count(c.id)
    )
    IO.puts("   Low Agreement (<50%): #{low_agreement} cases")
  end

  IO.puts("\n" <> String.duplicate("=", 80))
  IO.puts("✅ MIGRATION COMPLETE!")
  IO.puts(String.duplicate("=", 80))
  IO.puts("")

else
  IO.puts("\n❌ Migration cancelled by user")
end
