# FinBERT Sentiment Classification Implementation Plan

## 🎯 Executive Summary

Implement modular, Oban-ready FinBERT sentiment classification for the Volfefe Machine project. This issue provides a complete architecture, testing strategy, and implementation roadmap for integrating ML-based sentiment analysis on individual content items.

---

## 📊 Current State Analysis

### ✅ What's Built

1. **Intelligence Context** (`lib/volfefe_machine/intelligence.ex`)
   - ✅ Modular `classify_content(content_id)` function
   - ✅ Per-content classification (not batch JSON)
   - ✅ Proper Phoenix Context boundaries
   - ✅ Error handling with `{:ok, result}` | `{:error, reason}` tuples
   - ✅ `batch_classify_contents/1` for processing multiple IDs
   - ✅ Query functions for sentiment analysis

2. **Python FinBERT Service** (`priv/ml/classify.py`)
   - ✅ Standalone script accepting stdin
   - ✅ Returns JSON with sentiment, confidence, model_version, metadata
   - ✅ Uses `yiyanghkust/finbert-tone` model
   - ✅ Error handling with JSON error responses

3. **FinbertClient Port Integration** (`lib/volfefe_machine/intelligence/finbert_client.ex`)
   - ✅ Elixir Port communication with Python
   - ✅ 30-second timeout protection
   - ✅ JSON parsing with error handling
   - ✅ Logging for debugging

4. **Database Schema**
   - ✅ `classifications` table with proper foreign key to `contents`
   - ✅ Unique constraint on `content_id` (one classification per content)
   - ✅ JSONB `meta` field for raw scores and extensibility
   - ✅ `classified` boolean flag on `contents` table

### ❌ What's Missing

1. **Python Environment Setup**
   - ❌ `transformers` library not installed
   - ❌ `torch` (PyTorch) not installed
   - ❌ FinBERT model not downloaded (~2-3GB)

2. **End-to-End Testing**
   - ❌ Haven't tested full Elixir → Port → Python → FinBERT pipeline
   - ❌ No verification with real content from database

3. **Mix Task for Classification**
   - ❌ No CLI interface for running classifications
   - ❌ No batch processing capability with progress reporting

4. **Oban Integration**
   - ❌ Oban not added to dependencies
   - ❌ No worker module created
   - ❌ No queue configuration

---

## 🏗️ Architecture Decisions

### ✅ Decision 1: Individual Classification (Modular Design)

**Choice**: Process one content item at a time, not batch JSON imports.

**Rationale**:
- ✅ Supports Oban job-per-item pattern
- ✅ Better error isolation (one failure doesn't affect others)
- ✅ Progress tracking per item
- ✅ Retry logic per item
- ✅ Easier to test and debug

**Implementation**:
```elixir
# Already implemented in Intelligence context
def classify_content(content_id) do
  with {:ok, content} <- fetch_content(content_id),
       {:ok, text} <- validate_text(content),
       {:ok, result} <- call_finbert_service(text),
       {:ok, classification} <- store_classification(content_id, result) do
    {:ok, classification}
  end
end
```

### ✅ Decision 2: Oban-Ready Design

**Choice**: Design for future Oban integration from the start.

**Rationale**:
- ✅ FinBERT inference takes 1-3 seconds per item
- ✅ 100+ posts = background processing required
- ✅ Need retry logic for transient failures
- ✅ Want progress tracking and observability

**Future Oban Worker Structure**:
```elixir
defmodule VolfefeMachine.Intelligence.ClassificationWorker do
  use Oban.Worker,
    queue: :ml_classification,
    max_attempts: 3,
    unique: [period: 300, fields: [:worker, :args]]

  alias VolfefeMachine.Intelligence

  @impl Oban.Worker
  def perform(%Oban.Job{args: %{"content_id" => content_id}}) do
    case Intelligence.classify_content(content_id) do
      {:ok, _classification} -> :ok
      {:error, :content_not_found} -> :ok  # Don't retry
      {:error, :no_text_to_classify} -> :ok  # Don't retry
      {:error, reason} -> {:error, reason}  # Retry
    end
  end
end
```

### ✅ Decision 3: Python Service via Port

**Choice**: Use Elixir Port to call Python script (current implementation).

**Alternatives Considered**:
- ❌ GenServer-based Python process pool: More complex, not needed yet
- ❌ HTTP service: Adds network overhead, additional failure mode
- ❌ Pure Elixir with Nx/Bumblebee: Model not available, ecosystem immature

**Rationale**:
- ✅ Simple, battle-tested Port mechanism
- ✅ Process isolation (Python crashes don't crash BEAM)
- ✅ Easy to test (can call Python directly)
- ✅ Timeout protection (30s default)

### ✅ Decision 4: Test-First Approach

**Choice**: Start with 5-10 posts, validate pipeline, then scale.

**Testing Phases**:
1. **Phase 1**: Python environment setup and manual testing
2. **Phase 2**: Single content classification via IEx
3. **Phase 3**: Mix task with 5-10 posts
4. **Phase 4**: Full batch with all unclassified content
5. **Phase 5**: Oban integration for future classifications

---

## 🔧 Implementation Steps

### Step 1: Python Environment Setup

**Goal**: Install dependencies and verify FinBERT model loads.

**Commands**:
```bash
# Install Python ML dependencies
pip3 install torch transformers --upgrade

# Verify installation
python3 -c "import transformers; import torch; print('✅ Dependencies installed')"

# Test Python script directly (downloads model on first run)
cd /Users/holdenthomas/Code/paid-projects-2025/volfefe_machine
echo "Stock market hitting record highs!" | python3 priv/ml/classify.py
```

**Expected Output**:
```json
{
  "sentiment": "positive",
  "confidence": 0.95,
  "model_version": "finbert-tone-v1.0",
  "meta": {
    "raw_scores": {
      "positive": 0.95,
      "negative": 0.02,
      "neutral": 0.03
    }
  }
}
```

**Success Criteria**:
- ✅ Python script runs without errors
- ✅ FinBERT model downloads (~2-3GB, takes 5-10 minutes first time)
- ✅ JSON output matches expected format
- ✅ Sentiment classification is reasonable

**Time Estimate**: 15-20 minutes (includes model download)

---

### Step 2: Test Elixir → Python Pipeline

**Goal**: Verify FinbertClient Port communication works end-to-end.

**Test via IEx**:
```elixir
# Start IEx with project
iex -S mix

# Test FinbertClient directly
alias VolfefeMachine.Intelligence.FinbertClient

# Test 1: Basic classification
{:ok, result} = FinbertClient.classify("The market is crashing!")
IO.inspect(result)

# Test 2: Verify error handling
{:error, :no_text_provided} = FinbertClient.classify("")

# Test 3: Check timeout doesn't crash (if Python slow)
# Should complete in ~2-3 seconds
```

**Expected Behavior**:
- ✅ Port opens successfully
- ✅ Text sent to Python via stdin
- ✅ JSON response parsed correctly
- ✅ Result map has all required keys
- ✅ Errors handled gracefully

**Success Criteria**:
- ✅ No process crashes or timeout errors
- ✅ Sentiment values are `"positive"`, `"negative"`, or `"neutral"`
- ✅ Confidence is float between 0.0 and 1.0
- ✅ Logs show successful classification

**Time Estimate**: 10 minutes

---

### Step 3: Test Intelligence Context Integration

**Goal**: Verify full `classify_content/1` pipeline with database.

**Prerequisites**:
- Database has content records
- Content has non-null `text` field

**Test via IEx**:
```elixir
# Start IEx
iex -S mix

# Check available content
alias VolfefeMachine.Content
content_ids = Content.list_contents() |> Enum.take(5) |> Enum.map(& &1.id)
IO.inspect(content_ids, label: "First 5 content IDs")

# Test single classification
alias VolfefeMachine.Intelligence
{:ok, classification} = Intelligence.classify_content(List.first(content_ids))

IO.inspect(classification, label: "Classification Result")

# Verify stored in database
stored = Intelligence.get_classification_by_content(List.first(content_ids))
IO.inspect(stored, label: "Stored Classification")

# Test error cases
{:error, :content_not_found} = Intelligence.classify_content(999999)
```

**Expected Data Flow**:
```
content_id
  → Content.get_content(id)           [Database Query]
  → validate text not nil/empty       [Validation]
  → FinbertClient.classify(text)      [Port → Python → FinBERT]
  → create_classification(attrs)      [Database Insert]
  → {:ok, %Classification{}}          [Return Result]
```

**Success Criteria**:
- ✅ Content fetched from database
- ✅ FinBERT classification succeeds
- ✅ Classification stored in database
- ✅ Unique constraint prevents duplicates
- ✅ Error handling works for missing content

**Time Estimate**: 15 minutes

---

### Step 4: Create Mix Task for Batch Classification

**Goal**: Build `mix classify.contents` task to process N items.

**File**: `lib/mix/tasks/classify_contents.ex`

**Implementation**:
```elixir
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
    {opts, _remaining, _invalid} = OptionParser.parse(
      args,
      switches: [limit: :integer, all: :boolean, ids: :string, dry_run: :boolean],
      aliases: [l: :limit, a: :all, i: :ids, d: :dry_run]
    )

    # Get content IDs to classify
    content_ids = get_content_ids(opts)

    if Enum.empty?(content_ids) do
      Mix.shell().info("No content items to classify.")
    else
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
    from c in Content,
      left_join: cl in assoc(c, :classification),
      where: is_nil(cl.id) and not is_nil(c.text) and c.text != "",
      select: c.id,
      order_by: [asc: c.id]
  end

  defp dry_run(content_ids) do
    Mix.shell().info("DRY RUN - Would classify these content IDs:")

    content_ids
    |> Enum.each(fn id ->
      content = Content.get_content(id)
      text_preview = String.slice(content.text || "", 0, 60)
      Mix.shell().info("  [#{id}] #{text_preview}...")
    end)

    Mix.shell().info("\nRun without --dry-run to perform classification.")
  end

  defp classify_batch(content_ids) do
    total = length(content_ids)

    results = content_ids
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
        Mix.shell().info(
          "  ✅ #{classification.sentiment} (#{Float.round(classification.confidence, 2)}) " <>
          "- #{elapsed}ms\n"
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

    Mix.shell().info("\n" <> String.duplicate("=", 50))
    Mix.shell().info("Classification Summary")
    Mix.shell().info(String.duplicate("=", 50))
    Mix.shell().info("Total:      #{total}")
    Mix.shell().info("Successful: #{successful}")
    Mix.shell().info("Failed:     #{failed}")

    if successful > 0 do
      # Sentiment distribution
      sentiments = results
      |> Enum.filter(&match?({:ok, _, _}, &1))
      |> Enum.map(fn {:ok, _, classification} -> classification.sentiment end)
      |> Enum.frequencies()

      Mix.shell().info("\nSentiment Distribution:")
      Enum.each(sentiments, fn {sentiment, count} ->
        Mix.shell().info("  #{sentiment}: #{count}")
      end)
    end

    if failed > 0 do
      Mix.shell().info("\nFailed Content IDs:")
      results
      |> Enum.filter(&match?({:error, _, _}, &1))
      |> Enum.each(fn {:error, content_id, reason} ->
        Mix.shell().info("  [#{content_id}] #{reason}")
      end)
    end
  end
end
```

**Usage Examples**:
```bash
# Test with 5 posts first
mix classify.contents --limit 5

# Dry run to see what would be processed
mix classify.contents --limit 10 --dry-run

# Process all unclassified content
mix classify.contents --all

# Classify specific IDs
mix classify.contents --ids 1,5,10,15,20
```

**Success Criteria**:
- ✅ Mix task compiles without errors
- ✅ Arguments parsed correctly
- ✅ Progress shown for each classification
- ✅ Summary statistics printed
- ✅ Errors handled gracefully

**Time Estimate**: 30 minutes

---

### Step 5: Small Batch Testing (5-10 Posts)

**Goal**: Validate entire pipeline with small batch before full run.

**Process**:
```bash
# 1. Check database state
mix ecto.migrate  # Ensure migrations applied

# 2. Dry run to verify query works
mix classify.contents --limit 10 --dry-run

# 3. Run on 5 posts first
mix classify.contents --limit 5

# 4. Verify in database
iex -S mix
alias VolfefeMachine.Intelligence
Intelligence.list_classifications() |> length()  # Should be 5

# 5. Check sentiment distribution
Intelligence.list_by_sentiment("positive") |> length()
Intelligence.list_by_sentiment("negative") |> length()
Intelligence.list_by_sentiment("neutral") |> length()

# 6. If successful, increase to 10
mix classify.contents --limit 10
```

**Validation Checklist**:
- ✅ All 5 posts classified successfully
- ✅ No duplicate classifications (unique constraint works)
- ✅ Sentiment values are valid
- ✅ Confidence scores between 0.0-1.0
- ✅ Model version stored correctly
- ✅ Raw scores in metadata
- ✅ Processing time reasonable (~2-3s per post)

**Expected Issues & Solutions**:

| Issue | Solution |
|-------|----------|
| Python timeout | Increase timeout in FinbertClient |
| Port communication failure | Check Python path, verify script executable |
| Model download slow | First run takes longer, subsequent fast |
| Duplicate key error | Classification already exists, skip or update |
| Empty text field | Query already filters, but add validation |

**Success Criteria**:
- ✅ 100% success rate on small batch
- ✅ No crashes or timeouts
- ✅ Database entries match expectations
- ✅ Ready to scale to full dataset

**Time Estimate**: 20 minutes

---

### Step 6: Full Batch Processing (All ~100 Posts)

**Goal**: Process all unclassified content with monitoring.

**Commands**:
```bash
# Check how many unclassified
iex -S mix
alias VolfefeMachine.{Content, Repo}
import Ecto.Query

unclassified_count =
  from(c in Content,
    left_join: cl in assoc(c, :classification),
    where: is_nil(cl.id) and not is_nil(c.text),
    select: count(c.id)
  )
  |> Repo.one()

IO.puts("Unclassified: #{unclassified_count}")

# Exit IEx
exit()

# Run full classification
mix classify.contents --all
```

**Expected Duration**:
- ~100 posts × 2-3 seconds = 3-5 minutes total

**Monitoring**:
```bash
# Watch database updates in another terminal
watch -n 5 "psql volfefe_machine_dev -c 'SELECT sentiment, COUNT(*) FROM classifications GROUP BY sentiment;'"
```

**Success Criteria**:
- ✅ All content items processed
- ✅ Classification rate ~20-30 per minute
- ✅ No memory leaks or resource exhaustion
- ✅ Reasonable sentiment distribution (not all one sentiment)
- ✅ Database constraints enforced

**Post-Processing Validation**:
```elixir
# In IEx after completion
alias VolfefeMachine.Intelligence

# Check totals
total = Intelligence.list_classifications() |> length()

# Sentiment distribution
positive = Intelligence.list_by_sentiment("positive") |> length()
negative = Intelligence.list_by_sentiment("negative") |> length()
neutral = Intelligence.list_by_sentiment("neutral") |> length()

IO.puts("""
Total: #{total}
Positive: #{positive} (#{Float.round(positive / total * 100, 1)}%)
Negative: #{negative} (#{Float.round(negative / total * 100, 1)}%)
Neutral: #{neutral} (#{Float.round(neutral / total * 100, 1)}%)
""")

# High confidence predictions
high_conf = Intelligence.list_high_confidence(0.9) |> length()
IO.puts("High confidence (>0.9): #{high_conf}")
```

**Time Estimate**: 30 minutes (including validation)

---

## 🧪 Testing Strategy

### Phase 1: Unit Testing (Python)
```bash
# Test Python script directly
echo "Stocks rally on good news" | python3 priv/ml/classify.py
echo "Market crash imminent" | python3 priv/ml/classify.py
echo "No change in rates" | python3 priv/ml/classify.py
```

### Phase 2: Integration Testing (Elixir Port)
```elixir
# Test FinbertClient in IEx
alias VolfefeMachine.Intelligence.FinbertClient

# Positive sentiment
{:ok, result} = FinbertClient.classify("Great earnings report!")
assert result.sentiment == "positive"

# Negative sentiment
{:ok, result} = FinbertClient.classify("Company files bankruptcy")
assert result.sentiment == "negative"

# Neutral sentiment
{:ok, result} = FinbertClient.classify("Quarterly report released")
assert result.sentiment == "neutral"
```

### Phase 3: Context Testing (Database Integration)
```elixir
# Test Intelligence context
alias VolfefeMachine.Intelligence

# Create test content
content = VolfefeMachine.Content.create_content(%{
  text: "Stock market soars to new heights!",
  source_id: 1,
  external_id: "test-#{:rand.uniform(10000)}",
  author: "test",
  published_at: DateTime.utc_now()
})

# Classify
{:ok, classification} = Intelligence.classify_content(content.id)

# Verify
assert classification.sentiment in ["positive", "negative", "neutral"]
assert classification.confidence >= 0.0
assert classification.confidence <= 1.0
assert classification.model_version == "finbert-tone-v1.0"

# Test duplicate prevention
{:error, changeset} = Intelligence.classify_content(content.id)
assert changeset.errors[:content_id]
```

### Phase 4: Mix Task Testing
```bash
# Dry run
mix classify.contents --limit 3 --dry-run

# Small batch
mix classify.contents --limit 3

# Verify success
mix run -e "VolfefeMachine.Intelligence.list_classifications() |> length() |> IO.inspect()"
```

### Phase 5: Load Testing
```bash
# Time full batch
time mix classify.contents --all

# Monitor memory
ps aux | grep beam

# Check database size
psql volfefe_machine_dev -c "SELECT pg_size_pretty(pg_database_size('volfefe_machine_dev'));"
```

---

## 🚀 Future: Oban Integration Plan

### Phase 1: Add Oban Dependency

**File**: `mix.exs`
```elixir
defp deps do
  [
    # ... existing deps
    {:oban, "~> 2.17"}
  ]
end
```

### Phase 2: Configure Oban

**File**: `config/config.exs`
```elixir
config :volfefe_machine, Oban,
  repo: VolfefeMachine.Repo,
  queues: [
    default: 10,
    ml_classification: 5  # 5 concurrent FinBERT jobs
  ],
  plugins: [
    Oban.Plugins.Pruner,  # Clean up old jobs
    {Oban.Plugins.Cron,   # Scheduled jobs
     crontab: [
       # Classify new content every hour
       {"0 * * * *", VolfefeMachine.Intelligence.ScheduledClassificationWorker}
     ]}
  ]
```

### Phase 3: Add to Supervision Tree

**File**: `lib/volfefe_machine/application.ex`
```elixir
def start(_type, _args) do
  children = [
    # ... existing children
    {Oban, Application.fetch_env!(:volfefe_machine, Oban)}
  ]

  opts = [strategy: :one_for_one, name: VolfefeMachine.Supervisor]
  Supervisor.start_link(children, opts)
end
```

### Phase 4: Create Worker

**File**: `lib/volfefe_machine/intelligence/classification_worker.ex`
```elixir
defmodule VolfefeMachine.Intelligence.ClassificationWorker do
  use Oban.Worker,
    queue: :ml_classification,
    max_attempts: 3,
    unique: [period: 300, fields: [:worker, :args]]

  alias VolfefeMachine.Intelligence

  @impl Oban.Worker
  def perform(%Oban.Job{args: %{"content_id" => content_id}}) do
    case Intelligence.classify_content(content_id) do
      {:ok, _classification} ->
        :ok

      {:error, :content_not_found} ->
        # Don't retry, content deleted
        :ok

      {:error, :no_text_to_classify} ->
        # Don't retry, content has no text
        :ok

      {:error, reason} ->
        # Retry for transient failures
        {:error, reason}
    end
  end
end
```

### Phase 5: Enqueue Jobs

**Usage Examples**:
```elixir
# Single job
%{content_id: 123}
|> VolfefeMachine.Intelligence.ClassificationWorker.new()
|> Oban.insert()

# Batch enqueue all unclassified
unclassified_ids = get_unclassified_content_ids()

jobs = Enum.map(unclassified_ids, fn id ->
  VolfefeMachine.Intelligence.ClassificationWorker.new(%{content_id: id})
end)

Oban.insert_all(jobs)

# Scheduled classification (1 hour from now)
%{content_id: 456}
|> VolfefeMachine.Intelligence.ClassificationWorker.new(schedule_in: 3600)
|> Oban.insert()
```

### Phase 6: Observability

**Monitoring**:
```elixir
# Check queue status
Oban.check_queue(queue: :ml_classification)

# Job statistics
from(j in Oban.Job,
  where: j.queue == "ml_classification",
  group_by: j.state,
  select: {j.state, count(j.id)}
)
|> Repo.all()
```

**Benefits of Oban Integration**:
- ✅ Automatic retry logic (3 attempts)
- ✅ Concurrency control (5 concurrent jobs)
- ✅ Progress tracking via Oban UI
- ✅ Job uniqueness (no duplicate processing)
- ✅ Scheduled classification (cron jobs)
- ✅ Graceful shutdown (jobs not lost)
- ✅ Dead letter queue (persistent failures)

---

## ✅ Success Criteria

### Immediate (This Issue)

- [x] Python environment setup complete
  - [ ] `torch` and `transformers` installed
  - [ ] FinBERT model downloaded (~2-3GB)
  - [ ] Python script tested manually

- [x] Pipeline validated end-to-end
  - [ ] Elixir Port → Python communication works
  - [ ] JSON parsing succeeds
  - [ ] Database integration works
  - [ ] Error handling validated

- [x] Mix task implemented
  - [ ] `mix classify.contents` command works
  - [ ] Progress reporting functional
  - [ ] Summary statistics shown
  - [ ] Dry-run mode available

- [x] Small batch successful (5-10 posts)
  - [ ] All classifications successful
  - [ ] No crashes or timeouts
  - [ ] Sentiment distribution reasonable
  - [ ] Database constraints enforced

- [x] Full batch complete (~100 posts)
  - [ ] All unclassified content processed
  - [ ] Performance acceptable (~2-3s per item)
  - [ ] Sentiment distribution reasonable
  - [ ] High confidence predictions exist

### Future (Oban Integration)

- [ ] Oban dependency added
- [ ] Worker module created
- [ ] Supervision tree configured
- [ ] Background job processing working
- [ ] Retry logic validated
- [ ] Scheduled classification (optional)

---

## 📈 Performance Expectations

### Python/FinBERT
- **First Run**: 5-10 minutes (model download)
- **Subsequent Runs**: 2-3 seconds per classification
- **Memory Usage**: ~2-3GB (model in RAM)
- **CPU Usage**: High during inference (30-60% of 1 core)

### Elixir/Phoenix
- **Port Overhead**: ~50-100ms per call
- **Database Insert**: ~10-20ms per classification
- **Total Per Item**: 2-4 seconds
- **Batch of 100**: 3-5 minutes

### Oban (Future)
- **Throughput**: 5 concurrent workers = ~60-90 classifications/minute
- **Queue Time**: Depends on backlog, typically <1 minute
- **Retry Overhead**: 3 attempts × 2-3s = 6-9s worst case

---

## 🐛 Known Issues & Mitigations

### Issue 1: Python Model Download Slow
**Symptom**: First run takes 5-10 minutes
**Cause**: FinBERT model is ~2-3GB
**Mitigation**: Pre-download model with `python3 priv/ml/classify.py` before running batch

### Issue 2: Port Timeout on First Call
**Symptom**: 30-second timeout on first classification
**Cause**: Model loading takes time on cold start
**Mitigation**: Increase timeout to 60s for first call, or pre-warm model

### Issue 3: Duplicate Classification Attempts
**Symptom**: Unique constraint error
**Cause**: Content already classified
**Mitigation**: Query filters already-classified content, constraint prevents duplicates

### Issue 4: Memory Growth Over Time
**Symptom**: Python process memory increases
**Cause**: Model caching, potential memory leak
**Mitigation**: Port creates new Python process per call (isolated), no long-running process

### Issue 5: Non-English Text Performance
**Symptom**: Poor sentiment accuracy on non-English text
**Cause**: FinBERT trained on English financial text
**Mitigation**: Document limitation, consider language detection in future

---

## 📚 References

### Documentation
- [FinBERT Model](https://huggingface.co/yiyanghkust/finbert-tone)
- [Elixir Ports](https://hexdocs.pm/elixir/Port.html)
- [Oban Documentation](https://hexdocs.pm/oban/Oban.html)
- [Phoenix Contexts](https://hexdocs.pm/phoenix/contexts.html)

### Code Files
- `lib/volfefe_machine/intelligence.ex` - Intelligence context
- `lib/volfefe_machine/intelligence/finbert_client.ex` - Port client
- `lib/volfefe_machine/intelligence/classification.ex` - Schema
- `priv/ml/classify.py` - Python FinBERT service

---

## 🎯 Next Steps

1. **Setup Python Environment** (15-20 min)
   ```bash
   pip3 install torch transformers --upgrade
   echo "Test text" | python3 priv/ml/classify.py
   ```

2. **Test Port Communication** (10 min)
   ```elixir
   iex -S mix
   VolfefeMachine.Intelligence.FinbertClient.classify("Test text")
   ```

3. **Create Mix Task** (30 min)
   - Implement `lib/mix/tasks/classify_contents.ex`
   - Test with `--dry-run`

4. **Small Batch Test** (20 min)
   ```bash
   mix classify.contents --limit 5
   ```

5. **Full Batch** (30 min)
   ```bash
   mix classify.contents --all
   ```

6. **Validate Results** (15 min)
   - Check sentiment distribution
   - Verify high-confidence predictions
   - Spot-check random samples

**Total Estimated Time**: 2-2.5 hours

---

## 🤔 Decision Points

### When to Add Oban?
- **Now**: If you expect >500 classifications or want background processing immediately
- **Later**: If current batch approach is sufficient and you want to validate ML quality first
- **Recommendation**: Implement after validating sentiment quality with current batch

### When to Add GenServer Pool?
- **Now**: If single Python process is bottleneck (CPU-bound, >1000 items)
- **Later**: If Oban + concurrent workers is sufficient (5 concurrent = ~90/min)
- **Recommendation**: Wait until proven bottleneck, Oban likely sufficient

### When to Consider Bumblebee/Nx?
- **Now**: If you want pure Elixir stack and FinBERT models become Nx-compatible
- **Later**: Ecosystem maturing, not critical path
- **Recommendation**: Monitor Bumblebee progress, Python/Port is reliable for now

---

**Issue Created**: 2025-10-26
**Priority**: High
**Labels**: `ml`, `finbert`, `classification`, `architecture`, `implementation`
**Assignee**: Development Team
**Milestone**: Phase 2 - ML Integration
