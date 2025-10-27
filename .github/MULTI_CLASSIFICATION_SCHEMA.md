# Multi-Classification Schema Design: Collect Everything

**Issue Type**: Schema Design / Architecture
**Priority**: High
**Estimated Effort**: 8-12 hours (design + implementation)
**Created**: 2025-10-26

---

## Problem Statement

### Current Limitation: One Classification, One Model

**Current Schema**:
```elixir
create table(:classifications) do
  add :content_id, references(:contents), null: false
  add :sentiment, :string, null: false
  add :confidence, :float, null: false
  add :model_version, :string, null: false
  add :meta, :map, default: %{}

  timestamps()
end

# One classification per content
create unique_index(:classifications, [:content_id])
```

**Problem**: Can only store results from ONE model per content.

**What We Need**: Store results from MULTIPLE models per content.

---

## Core Philosophy: Collect Everything, Decide Later

### Principles

1. **Run ALL models on ALL content** - No smart routing, no assumptions
2. **Capture ALL metadata** - Every model, every field, everything
3. **Future-proof** - Easy to add more models without schema changes
4. **Data-driven** - Collect data first, analyze patterns, THEN optimize
5. **No premature optimization** - Don't guess which model is best, let data tell us

### Why This Approach?

**Instead of**:
- ❌ Keyword detection to route to "right" model
- ❌ Guessing which model works best
- ❌ Complex ensemble voting logic upfront

**We**:
- ✅ Run ALL models (FinBERT, DistilBERT, Twitter-RoBERTa, etc.)
- ✅ Store ALL results with full metadata
- ✅ Analyze 100-1000 posts of data
- ✅ Learn which models agree, disagree, and when
- ✅ THEN build sophisticated logic based on actual data

**Example**:
```
Content ID 1: "Tesla earnings beat expectations!"

Run ALL models:
  FinBERT:        positive (0.98) - 2500ms - {...metadata}
  DistilBERT:     positive (0.95) - 50ms - {...metadata}
  Twitter-RoBERTa: positive (0.92) - 100ms - {...metadata}

Store ALL results → Analyze later:
  - All agree = high confidence signal
  - Financial context detected (earnings keyword)
  - FinBERT + DistilBERT sufficient, Twitter-RoBERTa redundant?
```

After 1000 posts, we can answer:
- Which models agree most often?
- Which model is most accurate for financial content?
- Which model is fastest without sacrificing accuracy?
- When do models disagree, and is that useful?

---

## Schema Design Options

### Option 1: Separate Classifications Table (Recommended)

**Concept**: One row per model per content

**Schema**:
```elixir
create table(:model_classifications) do
  add :content_id, references(:contents, on_delete: :delete_all), null: false
  add :model_id, :string, null: false  # "finbert", "distilbert", "twitter_roberta"
  add :model_version, :string, null: false  # "v1.0", "v2.0", etc.

  # Core classification result
  add :sentiment, :string, null: false
  add :confidence, :float, null: false

  # Full metadata from model (raw_scores, processing, quality, etc.)
  add :meta, :map, default: %{}

  timestamps(type: :utc_datetime)
end

# One classification per content per model
create unique_index(:model_classifications, [:content_id, :model_id, :model_version])

# Query optimization
create index(:model_classifications, [:content_id])
create index(:model_classifications, [:model_id])
create index(:model_classifications, [:sentiment])
create index(:model_classifications, [:inserted_at])
```

**Example Data**:
```
id | content_id | model_id        | model_version | sentiment | confidence | meta         | inserted_at
---+------------+-----------------+---------------+-----------+------------+--------------+-------------
1  | 1          | finbert         | v1.0          | positive  | 0.98       | {...}        | 2025-10-26
2  | 1          | distilbert      | v1.0          | positive  | 0.95       | {...}        | 2025-10-26
3  | 1          | twitter_roberta | v1.0          | positive  | 0.92       | {...}        | 2025-10-26
4  | 2          | finbert         | v1.0          | neutral   | 0.99       | {...}        | 2025-10-26
5  | 2          | distilbert      | v1.0          | negative  | 0.97       | {...}        | 2025-10-26
```

**Pros**:
- ✅ **Easy to query individual models**: `WHERE model_id = 'finbert'`
- ✅ **Easy to compare models**: Join on content_id, compare sentiments
- ✅ **Easy to add new models**: Just insert new rows, no schema change
- ✅ **Model versioning built-in**: Can store v1.0 and v2.0 side-by-side
- ✅ **Clean relational design**: Normalized, clear relationships
- ✅ **Performance**: Indexed queries fast even with millions of rows

**Cons**:
- ⚠️ **More rows**: 3 models × 87 posts = 261 rows (vs 87 in current schema)
- ⚠️ **Queries need joins**: To get all models for one content, need GROUP BY or JOIN

**Queries**:
```elixir
# Get all classifications for one content
def get_all_classifications(content_id) do
  ModelClassification
  |> where([mc], mc.content_id == ^content_id)
  |> Repo.all()
end

# Compare two models
def compare_models(model_id_1, model_id_2) do
  query = """
    SELECT
      c.id,
      c.text,
      mc1.sentiment as #{model_id_1}_sentiment,
      mc1.confidence as #{model_id_1}_confidence,
      mc2.sentiment as #{model_id_2}_sentiment,
      mc2.confidence as #{model_id_2}_confidence
    FROM contents c
    JOIN model_classifications mc1 ON mc1.content_id = c.id AND mc1.model_id = $1
    JOIN model_classifications mc2 ON mc2.content_id = c.id AND mc2.model_id = $2
  """

  Ecto.Adapters.SQL.query!(Repo, query, [model_id_1, model_id_2])
end

# Find disagreements
def find_disagreements do
  query = """
    SELECT
      content_id,
      COUNT(DISTINCT sentiment) as unique_sentiments,
      ARRAY_AGG(model_id || ': ' || sentiment) as classifications
    FROM model_classifications
    GROUP BY content_id
    HAVING COUNT(DISTINCT sentiment) > 1
  """

  Ecto.Adapters.SQL.query!(Repo, query)
end

# Model performance comparison
def model_stats(model_id) do
  ModelClassification
  |> where([mc], mc.model_id == ^model_id)
  |> group_by([mc], mc.sentiment)
  |> select([mc], {mc.sentiment, count(mc.id), avg(mc.confidence)})
  |> Repo.all()
end
```

**Storage Estimate**:
```
Per classification:
  - Fixed fields: ~80 bytes
  - Meta JSONB: ~400 bytes (with comprehensive metadata from Phase 2.5)
  - Total: ~480 bytes per classification

For 87 posts × 3 models = 261 classifications:
  - Storage: ~125 KB

For 10,000 posts × 3 models = 30,000 classifications:
  - Storage: ~14 MB

For 100,000 posts × 3 models = 300,000 classifications:
  - Storage: ~140 MB
```

**Verdict**: ✅ **Recommended** - Clean, flexible, performant

---

### Option 2: Embedded Array in Classifications Table

**Concept**: Keep current table, store multiple model results in JSONB array

**Schema**:
```elixir
create table(:classifications) do
  add :content_id, references(:contents), null: false

  # Aggregate/primary result (from ensemble or primary model)
  add :sentiment, :string, null: false
  add :confidence, :float, null: false
  add :model_version, :string  # "ensemble-v1.0" or "finbert-v1.0"

  # All model results stored in meta
  add :meta, :map, default: %{}

  timestamps()
end

create unique_index(:classifications, [:content_id])
```

**Example Data**:
```json
{
  "content_id": 1,
  "sentiment": "positive",  // Aggregate result
  "confidence": 0.95,
  "model_version": "ensemble-v1.0",
  "meta": {
    "models": {
      "finbert": {
        "sentiment": "positive",
        "confidence": 0.98,
        "model_version": "v1.0",
        "meta": {
          "processing": {"latency_ms": 2500},
          "raw_scores": {"positive": 0.98, "neutral": 0.01, "negative": 0.01},
          "quality": {"score_margin": 0.97}
        }
      },
      "distilbert": {
        "sentiment": "positive",
        "confidence": 0.95,
        "model_version": "v1.0",
        "meta": {
          "processing": {"latency_ms": 50},
          "raw_scores": {"positive": 0.95, "negative": 0.05},
          "quality": {"score_margin": 0.90}
        }
      },
      "twitter_roberta": {
        "sentiment": "positive",
        "confidence": 0.92,
        "model_version": "v1.0",
        "meta": {
          "processing": {"latency_ms": 100},
          "raw_scores": {"positive": 0.92, "neutral": 0.05, "negative": 0.03}
        }
      }
    },
    "ensemble": {
      "method": "store_all",
      "agreement": true,
      "all_agree": true
    }
  }
}
```

**Pros**:
- ✅ **No schema migration**: Uses existing table
- ✅ **One row per content**: Simple to query by content
- ✅ **All data in one place**: No joins needed

**Cons**:
- ❌ **Can't query individual models easily**: Need JSONB queries
- ❌ **Can't index model results**: JSONB indexes complex and slow
- ❌ **Hard to compare models**: Must extract from JSONB in application code
- ❌ **Large JSONB documents**: ~1-2KB per row with 3 models
- ❌ **Difficult analytics**: Can't easily answer "how often does FinBERT disagree?"

**Queries**:
```elixir
# Get FinBERT result for content
def get_finbert_result(content_id) do
  classification = Repo.get_by(Classification, content_id: content_id)
  get_in(classification.meta, ["models", "finbert"])
end

# Find disagreements (complex JSONB query)
def find_disagreements do
  query = """
    SELECT
      c.id,
      c.meta->'models'
    FROM classifications c
    WHERE (
      SELECT COUNT(DISTINCT sentiment)
      FROM jsonb_each(c.meta->'models')
      WHERE value->>'sentiment' IS NOT NULL
    ) > 1
  """

  Ecto.Adapters.SQL.query!(Repo, query)
end
```

**Verdict**: ❌ **Not Recommended** - Hard to query, analyze, and scale

---

### Option 3: Hybrid Approach

**Concept**: Separate table for model results, keep aggregate in classifications

**Schema**:
```elixir
# Aggregate/primary classification (for quick queries)
create table(:classifications) do
  add :content_id, references(:contents), null: false
  add :sentiment, :string, null: false
  add :confidence, :float, null: false
  add :method, :string  # "ensemble", "primary_model", etc.
  add :meta, :map

  timestamps()
end

create unique_index(:classifications, [:content_id])

# Detailed model classifications
create table(:model_classifications) do
  add :content_id, references(:contents), null: false
  add :classification_id, references(:classifications), null: false
  add :model_id, :string, null: false
  add :model_version, :string, null: false
  add :sentiment, :string, null: false
  add :confidence, :float, null: false
  add :meta, :map

  timestamps()
end

create unique_index(:model_classifications, [:content_id, :model_id, :model_version])
create index(:model_classifications, [:classification_id])
```

**Pros**:
- ✅ **Best of both worlds**: Fast aggregate queries + detailed model data
- ✅ **Backward compatible**: Existing queries still work on classifications table
- ✅ **Flexible**: Can query aggregate or drill into models

**Cons**:
- ⚠️ **Two tables to manage**: More complexity
- ⚠️ **Redundant data**: Aggregate duplicates one of the model results

**Verdict**: 🤔 **Overkill for now** - Start with Option 1, add this if needed

---

## Model Storage: Table vs Configuration

### Question: Do We Need a `models` Table?

**Option A: Configuration Only** (Recommended for now)

**Concept**: Models defined in config, not database

```elixir
# config/models.exs
config :volfefe_machine, :sentiment_models, [
  %{
    id: "finbert",
    name: "FinBERT",
    python_model: "yiyanghkust/finbert-tone",
    version: "v1.0",
    enabled: true
  },
  %{
    id: "distilbert",
    name: "DistilBERT SST-2",
    python_model: "distilbert-base-uncased-finetuned-sst-2-english",
    version: "v1.0",
    enabled: true
  },
  %{
    id: "twitter_roberta",
    name: "Twitter-RoBERTa",
    python_model: "cardiffnlp/twitter-roberta-base-sentiment-latest",
    version: "v1.0",
    enabled: true
  }
]
```

**Pros**:
- ✅ **Simple**: No extra table
- ✅ **Fast**: Config loaded at startup
- ✅ **Flexible**: Easy to add/remove models
- ✅ **Versioned**: Config changes tracked in git

**Cons**:
- ⚠️ **Can't toggle models at runtime**: Need app restart
- ⚠️ **No model metadata in DB**: Can't query "which models were run when"

**Verdict**: ✅ **Start here** - Add DB table later if needed

---

**Option B: Database Table** (Future enhancement)

**Concept**: Store model registry in database

```elixir
create table(:models) do
  add :model_id, :string, null: false  # "finbert"
  add :name, :string, null: false
  add :python_model, :string, null: false
  add :version, :string, null: false
  add :enabled, :boolean, default: true
  add :config, :map  # Additional model configuration

  timestamps()
end

create unique_index(:models, [:model_id, :version])
```

**When to add this**:
- Need to toggle models without deployment
- Want to track when models were added/removed
- Need model-specific configuration per environment

**Verdict**: 🔮 **Phase 4** - Not needed yet

---

## Python Script Changes

### Current: Single Model

```python
def main():
    classifier = load_model()  # One model
    text = sys.stdin.read().strip()
    result = classify_text(classifier, text)
    print(json.dumps(result))
```

### New: Multiple Models

```python
def load_all_models():
    """Load all enabled models from config."""
    return {
        "finbert": pipeline("sentiment-analysis", model="yiyanghkust/finbert-tone", device=-1),
        "distilbert": pipeline("sentiment-analysis", model="distilbert-base-uncased-finetuned-sst-2-english", device=-1),
        "twitter_roberta": pipeline("sentiment-analysis", model="cardiffnlp/twitter-roberta-base-sentiment-latest", device=-1)
    }

def classify_with_all_models(classifiers, text):
    """Run ALL models and return ALL results."""
    results = {}

    for model_id, classifier in classifiers.items():
        start_time = time.time()

        # Classify with this model
        result = classify_text(classifier, text, model_id)

        results[model_id] = result

    return results

def main():
    # Load ALL models at startup
    classifiers = load_all_models()

    # Read text
    text = sys.stdin.read().strip()

    # Run ALL models
    all_results = classify_with_all_models(classifiers, text)

    # Return ALL results
    print(json.dumps({
        "models": all_results,
        "timestamp": time.time()
    }))
```

**Output Format**:
```json
{
  "models": {
    "finbert": {
      "sentiment": "positive",
      "confidence": 0.98,
      "model_version": "v1.0",
      "meta": { "processing": {"latency_ms": 2500}, ... }
    },
    "distilbert": {
      "sentiment": "positive",
      "confidence": 0.95,
      "model_version": "v1.0",
      "meta": { "processing": {"latency_ms": 50}, ... }
    },
    "twitter_roberta": {
      "sentiment": "positive",
      "confidence": 0.92,
      "model_version": "v1.0",
      "meta": { "processing": {"latency_ms": 100}, ... }
    }
  },
  "timestamp": 1698342156.789
}
```

---

## Elixir Intelligence Context Changes

### Current: Store One Classification

```elixir
defp store_classification(content_id, result) do
  attrs = %{
    content_id: content_id,
    sentiment: result.sentiment,
    confidence: result.confidence,
    model_version: result.model_version,
    meta: result.meta
  }

  create_classification(attrs)
end
```

### New: Store Multiple Classifications

```elixir
defp store_all_classifications(content_id, all_results) do
  # all_results = %{"finbert" => {...}, "distilbert" => {...}, ...}

  results =
    for {model_id, result} <- all_results do
      attrs = %{
        content_id: content_id,
        model_id: model_id,
        model_version: result.model_version,
        sentiment: result.sentiment,
        confidence: result.confidence,
        meta: result.meta
      }

      create_model_classification(attrs)
    end

  # Return list of created classifications
  {:ok, results}
end
```

---

## Analysis Queries (Data-Driven Learning)

### After collecting 100-1000 posts, we can analyze:

**Query 1: Model Agreement Rate**

```elixir
def model_agreement_rate do
  query = """
    SELECT
      content_id,
      COUNT(DISTINCT sentiment) = 1 as all_agree,
      ARRAY_AGG(model_id || ': ' || sentiment) as results
    FROM model_classifications
    GROUP BY content_id
  """

  results = Ecto.Adapters.SQL.query!(Repo, query)

  total = length(results.rows)
  agreed = Enum.count(results.rows, fn [_, all_agree, _] -> all_agree end)

  %{
    total: total,
    all_agree: agreed,
    agreement_rate: Float.round(agreed / total, 3),
    disagreements: total - agreed
  }
end
```

**Query 2: Model Performance by Sentiment**

```elixir
def model_sentiment_distribution(model_id) do
  ModelClassification
  |> where([mc], mc.model_id == ^model_id)
  |> group_by([mc], mc.sentiment)
  |> select([mc], {mc.sentiment, count(mc.id)})
  |> Repo.all()
  |> Enum.into(%{})
end

# Usage:
finbert_dist = model_sentiment_distribution("finbert")
# %{"positive" => 45, "neutral" => 55, "negative" => 0}

distilbert_dist = model_sentiment_distribution("distilbert")
# %{"positive" => 55, "negative" => 45, "neutral" => 0}
```

**Query 3: Find Specific Disagreement Patterns**

```elixir
def find_pattern(finbert_sentiment, distilbert_sentiment) do
  query = """
    SELECT
      c.id,
      c.text,
      fb.confidence as finbert_confidence,
      db.confidence as distilbert_confidence
    FROM contents c
    JOIN model_classifications fb ON fb.content_id = c.id AND fb.model_id = 'finbert'
    JOIN model_classifications db ON db.content_id = c.id AND db.model_id = 'distilbert'
    WHERE fb.sentiment = $1 AND db.sentiment = $2
  """

  Ecto.Adapters.SQL.query!(Repo, query, [finbert_sentiment, distilbert_sentiment])
end

# Find cases where FinBERT says neutral but DistilBERT says negative
find_pattern("neutral", "negative")
```

**Query 4: Average Processing Time by Model**

```elixir
def avg_latency_by_model do
  query = """
    SELECT
      model_id,
      AVG((meta->'processing'->>'latency_ms')::int) as avg_latency_ms,
      MIN((meta->'processing'->>'latency_ms')::int) as min_latency_ms,
      MAX((meta->'processing'->>'latency_ms')::int) as max_latency_ms
    FROM model_classifications
    GROUP BY model_id
    ORDER BY avg_latency_ms ASC
  """

  Ecto.Adapters.SQL.query!(Repo, query)
end

# Expected output:
# distilbert: avg 50ms, min 25ms, max 100ms
# twitter_roberta: avg 100ms, min 80ms, max 150ms
# finbert: avg 2500ms, min 2000ms, max 3500ms
```

---

## Implementation Plan

### Phase 1: Schema & Database (2-3 hours)

**Tasks**:
- [ ] Create `model_classifications` table migration
- [ ] Update Intelligence schema module
- [ ] Add indexes for common queries
- [ ] Test migration on dev database

**Deliverables**:
- Migration file
- `ModelClassification` schema module
- Schema documentation

---

### Phase 2: Python Multi-Model Script (3-4 hours)

**Tasks**:
- [ ] Update `classify.py` to load all models
- [ ] Implement `classify_with_all_models` function
- [ ] Return results in new format (models map)
- [ ] Test with sample text, verify all models run

**Deliverables**:
- Updated `priv/ml/classify.py`
- Test script to verify all models work
- Performance benchmarks (total time with 3 models)

---

### Phase 3: Elixir Integration (2-3 hours)

**Tasks**:
- [ ] Update FinbertClient to parse new multi-model format
- [ ] Update Intelligence context to store multiple classifications
- [ ] Update Mix task to handle multiple results
- [ ] Test on 5 sample posts

**Deliverables**:
- Updated `FinbertClient`
- Updated `Intelligence` context
- Passing tests

---

### Phase 4: Data Collection & Analysis (1-2 hours)

**Tasks**:
- [ ] Reclassify 20 posts with all models
- [ ] Run analysis queries (agreement rate, distribution, etc.)
- [ ] Document patterns and insights
- [ ] Identify optimization opportunities

**Deliverables**:
- Analysis report
- Initial insights on model agreement/disagreement
- Recommendations for future phases

---

## Success Criteria

### Data Collection

✅ **All models run**: FinBERT, DistilBERT, Twitter-RoBERTa on every post
✅ **All metadata captured**: Processing time, confidence, raw scores, quality metrics
✅ **Storage efficient**: <500 bytes per classification, scales to 100K+ posts
✅ **Queryable**: Can analyze by model, by content, by agreement

### Analysis Capability

✅ **Model comparison**: Easy to compare any two models
✅ **Agreement analysis**: Can calculate agreement rates
✅ **Pattern detection**: Find specific disagreement cases
✅ **Performance tracking**: Monitor latency, confidence by model

### Future-Proofing

✅ **Add models easily**: Just update config, no schema change
✅ **Model versioning**: Can store v1.0 and v2.0 side-by-side
✅ **Flexible queries**: Can answer questions we haven't thought of yet
✅ **No assumptions**: Collect data first, optimize later

---

## Open Questions

### 1. Schema Choice

**Recommendation**: Option 1 (Separate `model_classifications` table)

**Rationale**:
- Easy to query individual models
- Easy to add new models
- Clean relational design
- Performant at scale

**Alternative**: Option 2 (JSONB array) if you strongly prefer fewer tables

**Decision needed**: Which schema option?

---

### 2. Model Configuration

**Recommendation**: Start with config file (Option A)

**Rationale**:
- Simple, fast, no extra table
- Can upgrade to DB table later if needed

**Decision needed**: Config file or DB table?

---

### 3. Initial Model Set

**Recommendation**: Start with 3 models

1. **FinBERT** - Financial sentiment baseline
2. **DistilBERT** - General sentiment + political attacks
3. **Twitter-RoBERTa** - Social media tone

**Could add later**:
- BERT large (slower, more accurate?)
- Domain-specific models
- Fine-tuned Trump model

**Decision needed**: Which models to include initially?

---

### 4. Performance Considerations

**Question**: Run models sequentially or in parallel?

**Sequential** (simpler):
- FinBERT: 2500ms
- DistilBERT: 50ms
- Twitter-RoBERTa: 100ms
- **Total: ~2650ms** (similar to current FinBERT-only)

**Parallel** (faster, more complex):
- All 3 models: ~2500ms (limited by slowest)
- Requires Python multiprocessing
- **Total: ~2500ms** (same as FinBERT alone!)

**Recommendation**: Start sequential, optimize to parallel in Phase 4

**Decision needed**: Sequential or parallel for initial implementation?

---

## Next Actions

**Before Implementation**:
1. **Review and approve**: Schema design (Option 1 recommended)
2. **Decide**: Config vs DB table for model registry (config recommended)
3. **Confirm**: Initial model set (FinBERT + DistilBERT + Twitter-RoBERTa)
4. **Approve**: Sequential execution for now (parallel optimization later)

**After Approval**:
1. Create migration for `model_classifications` table
2. Update Python script to run all models
3. Update Elixir code to store all results
4. Test on 20 posts, analyze results

**Estimated Total Time**: 8-12 hours (all phases)

---

## Summary

**Core Idea**: Run ALL models, capture ALL data, learn from patterns

**Schema**: Separate `model_classifications` table (one row per model per content)

**Philosophy**: No assumptions, no smart routing - just collect everything and analyze

**Benefit**: After 100-1000 posts, we'll have data to answer:
- Which models agree most?
- Which model is best for which content type?
- When is disagreement useful vs noise?
- Can we optimize (skip models, use faster models, etc.)?

**Then**: Build sophisticated logic based on actual data, not assumptions

---

**Created**: 2025-10-26
**Status**: Proposed - Awaiting Approval
**Effort**: 8-12 hours
**Priority**: High
