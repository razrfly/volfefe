# Issue #20: Multi-Model Architecture - Hybrid Approach (APPROVED)

**Status**: Architectural Decision - Approved
**Depends On**: Issue #18 (schema design), Issue #13 (Phase 2.5 audit)
**Builds Upon**: Existing `classifications` table
**Phase**: 2.5 Implementation
**Priority**: High

---

## Decision Summary

**APPROVED ARCHITECTURE**: Hybrid two-table approach

1. ✅ **Keep existing `classifications` table** - evolving consensus/intelligence layer
2. ✅ **Add new `model_classifications` table** - immutable raw model results
3. ✅ **Model configuration**: Config file only (not database)
4. ✅ **Initial models**: DistilBERT, Twitter-RoBERTa, FinBERT (3 models)

---

## Architecture Overview

```
┌─────────────────────────────────────────────────────────────┐
│                    APPLICATION LAYER                         │
│              (Trading signals, dashboards, API)              │
└─────────────────────────────────────────────────────────────┘
                              ↑
                              │
┌─────────────────────────────────────────────────────────────┐
│              INTELLIGENCE LAYER (Evolving)                   │
│                                                              │
│  classifications table (one row per content)                │
│  ├─ sentiment: "negative"        ← Consensus from models    │
│  ├─ confidence: 0.85             ← Weighted average         │
│  ├─ primary_target: "Canada"     ← From Issue #19 (future)  │
│  ├─ target_industries: [...]     ← From Issue #19 (future)  │
│  └─ model_version: "v1.0"        ← Versioned consensus      │
│                                                              │
└─────────────────────────────────────────────────────────────┘
                              ↑
                    Synthesized from
                              ↓
┌─────────────────────────────────────────────────────────────┐
│               RAW DATA LAYER (Immutable)                     │
│                                                              │
│  model_classifications table (3 rows per content)           │
│  ├─ Row 1: distilbert      → negative (0.9757)              │
│  ├─ Row 2: twitter_roberta → negative (0.7525)              │
│  └─ Row 3: finbert         → neutral  (0.9982)              │
│                                                              │
│  [Future: content_entities from Issue #19]                  │
│  [Future: topic_classifications, pattern_matches, etc.]     │
│                                                              │
└─────────────────────────────────────────────────────────────┘
```

---

## Table Schemas

### Existing: `classifications` (Consensus Layer)

**Current Schema** (Phase 2.5):
```elixir
schema "classifications" do
  belongs_to :content, VolfefeMachine.Content

  field :sentiment, :string              # Consensus: "positive", "negative", "neutral"
  field :confidence, :float              # Weighted confidence score
  field :model_version, :string          # Consensus algorithm version
  field :meta, :map                      # Flexible metadata storage

  timestamps(type: :utc_datetime)
end
```

**Future Evolution** (Phase 3+):
```elixir
# classifications table will grow as we add more intelligence
schema "classifications" do
  belongs_to :content, VolfefeMachine.Content

  # Sentiment (from multi-model consensus)
  field :sentiment, :string
  field :confidence, :float

  # Entities & Targets (from Issue #19)
  field :primary_target, :string                    # Main entity: "Canada", "Tesla"
  field :all_targets, {:array, :string}             # All extracted targets
  field :target_industries, {:array, :string}       # ["trade", "automotive"]
  field :affected_tickers, {:array, :string}        # ["EWC", "TSLA"]

  # Future enhancements
  field :topic_category, :string                    # "trade_war", "tech_policy"
  field :attack_severity, :float                    # 0.0-1.0 how aggressive?
  field :market_relevance, :float                   # 0.0-1.0 trading importance

  # Versioning
  field :model_version, :string                     # Algorithm version
  field :meta, :map

  timestamps(type: :utc_datetime)
end
```

### New: `model_classifications` (Raw Model Results)

**Schema**:
```elixir
defmodule VolfefeMachine.Intelligence.ModelClassification do
  use Ecto.Schema
  import Ecto.Changeset

  schema "model_classifications" do
    belongs_to :content, VolfefeMachine.Content

    # Model identification
    field :model_id, :string          # "distilbert", "twitter_roberta", "finbert"
    field :model_version, :string     # Full HuggingFace model path

    # Classification results
    field :sentiment, :string         # "positive", "negative", "neutral"
    field :confidence, :float         # 0.0-1.0

    # Complete metadata (same as Phase 2.5 meta field)
    field :meta, :map                 # {raw_scores, processing, text_info, quality, etc.}

    timestamps(type: :utc_datetime)
  end

  def changeset(model_classification, attrs) do
    model_classification
    |> cast(attrs, [:content_id, :model_id, :model_version, :sentiment, :confidence, :meta])
    |> validate_required([:content_id, :model_id, :model_version, :sentiment, :confidence])
    |> validate_inclusion(:sentiment, ["positive", "negative", "neutral"])
    |> validate_number(:confidence, greater_than_or_equal_to: 0.0, less_than_or_equal_to: 1.0)
    |> foreign_key_constraint(:content_id)
  end
end
```

**Migration**:
```elixir
defmodule VolfefeMachine.Repo.Migrations.CreateModelClassifications do
  use Ecto.Migration

  def change do
    create table(:model_classifications) do
      add :content_id, references(:contents, on_delete: :delete_all), null: false
      add :model_id, :string, null: false
      add :model_version, :string, null: false
      add :sentiment, :string, null: false
      add :confidence, :float, null: false
      add :meta, :map, default: %{}

      timestamps(type: :utc_datetime)
    end

    # Indexes
    create index(:model_classifications, [:content_id])
    create index(:model_classifications, [:model_id])
    create index(:model_classifications, [:sentiment])
    create index(:model_classifications, [:inserted_at])

    # Unique constraint: one result per model per content
    create unique_index(:model_classifications, [:content_id, :model_id, :model_version],
                        name: :model_classifications_unique_idx)
  end
end
```

---

## Model Configuration (Config File)

**File**: `config/ml_models.exs`

```elixir
import Config

config :volfefe_machine, :sentiment_models,
  models: [
    %{
      id: "distilbert",
      name: "distilbert-base-uncased-finetuned-sst-2-english",
      type: "sentiment",
      enabled: true,
      weight: 0.4,  # For weighted consensus
      notes: "General sentiment, fastest, binary classification"
    },
    %{
      id: "twitter_roberta",
      name: "cardiffnlp/twitter-roberta-base-sentiment-latest",
      type: "sentiment",
      enabled: true,
      weight: 0.4,
      notes: "Social media trained, good for informal text"
    },
    %{
      id: "finbert",
      name: "yiyanghkust/finbert-tone",
      type: "sentiment",
      enabled: true,
      weight: 0.2,  # Lower weight - proven to be poor for political content
      notes: "Financial news trained, poor for political content but kept for comparison"
    }
  ]

# Python script path
config :volfefe_machine, :ml_scripts,
  multi_model_classifier: "priv/ml/classify_multi_model.py"
```

**Why Config File?**
- ✅ Easy to enable/disable models without code changes
- ✅ Easy to adjust consensus weights
- ✅ No database complexity for model management
- ✅ Version controlled with code
- ✅ Models are installed locally anyway (must match config)

---

## Key Advantages

### 1. Backwards Compatibility
```elixir
# Existing code continues to work
Content
|> Repo.preload(:classification)
|> Map.get(:classification)
|> Map.get(:sentiment)
# Still returns sentiment - no breaking changes
```

### 2. Evolution Path
`classifications` table grows as intelligence improves:

**Phase 2.5** (Current):
- sentiment, confidence, model_version

**Phase 3** (Issue #19):
- + primary_target, all_targets, target_industries, affected_tickers

**Phase 4** (Future):
- + topic_category, attack_severity, market_relevance

### 3. Debuggable & Auditable
```elixir
# See exactly why consensus was reached
def explain_classification(content_id) do
  classification = get_classification(content_id)
  model_votes = get_model_classifications(content_id)

  # Shows all model votes + weighted consensus logic
end
```

---

## Implementation Checklist

### Part 1: Schema & Migration (2-3 hours)
- [ ] Create `model_classifications` migration
- [ ] Create `ModelClassification` schema module
- [ ] Add model config to `config/ml_models.exs`
- [ ] Run migration
- [ ] Test schema with sample data

### Part 2: Multi-Model Python Script (3-4 hours)
- [ ] Create `priv/ml/classify_multi_model.py`
- [ ] Load 3 models (DistilBERT, Twitter-RoBERTa, FinBERT)
- [ ] Run all models on input text
- [ ] Output JSON with all results
- [ ] Test script standalone

### Part 3: Elixir Integration (3-4 hours)
- [ ] Create `MultiModelClient` module
- [ ] Update `Intelligence.Classifier` for multi-model
- [ ] Implement `Consensus` module (weighted vote)
- [ ] Update Mix task
- [ ] Test on sample content

### Part 4: Data Migration (2-3 hours)
- [ ] Backfill existing classifications as FinBERT
- [ ] Run new models on all content
- [ ] Verify consensus calculations
- [ ] Compare before/after distributions

### Part 5: Testing & Validation (2-3 hours)
- [ ] Unit tests for consensus algorithm
- [ ] Test known examples (Canada fraud post)
- [ ] Verify metadata preservation
- [ ] Performance testing

**Total Estimated Time**: 12-17 hours

---

## Success Criteria

✅ Store results from 3 models per content
✅ Calculate weighted consensus sentiment  
✅ Preserve all model metadata
✅ Backwards compatible with existing code
✅ Improve negative detection from 2% to 30-40%
✅ Total latency <1 second for 3 models
✅ Easy to add/remove models via config

---

## Dependencies

**Requires**:
- Python 3.x with transformers
- PostgreSQL with JSONB
- Issue #13 Phase 2.5 complete

**Enables**:
- Issue #19 (entities) - synergy with multi-model approach
