# Issue #19: Entity and Target Identification Schema

**Status**: Design Specification
**Depends On**: Issue #18 (Multi-Model Classification)
**Phase**: 2.5 Enhancement
**Priority**: High - Core Trading Strategy Requirement

---

## Overarching Goal

**Identify which industry, company, or business entity is being targeted by Trump's content, particularly when sentiment is negative.**

**Why This Matters**: For trading strategy, we need to know not just THAT Trump is negative, but **WHO/WHAT he's targeting** so we can identify affected stocks, sectors, and industries.

---

## Current State vs. Goal

### What We Have After Issue #18
```
Text: "Canada was caught, red handed, putting up a fraudulent advertisement..."
Classification:
  - DistilBERT: negative (97.57%)
  - Twitter-RoBERTa: negative (75.25%)
  - FinBERT: neutral (99.82%)
```

### What We Need (Goal State)
```
Text: "Canada was caught, red handed, putting up a fraudulent advertisement..."
Classification:
  - DistilBERT: negative (97.57%)
  - Twitter-RoBERTa: negative (75.25%)
  - FinBERT: neutral (99.82%)
Entities:
  - Organizations: ["Canada", "Canadian Government"]
  - Persons: []
  - Locations: ["Canada"]
  - Industries: ["Government", "International Trade"]
  - Companies: []
Targets:
  - Primary: "Canadian Government"
  - Secondary: "International Trade Policy"
Entity-Sentiment Correlation:
  - Canada: negative (attack)
  - Canadian Government: negative (accusation)
```

---

## Core Philosophy (Same as Issue #18)

**"Run multiple models, collect everything, analyze patterns, decide later"**

- Run ALL entity extraction models on ALL content
- Store ALL extracted entities and metadata
- No smart filtering - capture everything
- Analyze 100-1000 posts to learn patterns
- Figure out best approach AFTER collecting data

**No premature optimization. No assumptions.**

---

## Schema Design

### Option 1: Separate Entities Table (Recommended)

**Advantages**:
- Clean separation of sentiment vs. entities
- Easy to query by entity type, name, or industry
- Simple to add more NER models
- Efficient for "show all content mentioning Tesla"
- Natural fit for entity-sentiment correlation

**Schema**:
```elixir
# Migration: priv/repo/migrations/YYYYMMDDHHMMSS_create_content_entities.exs
defmodule VolfefeMachine.Repo.Migrations.CreateContentEntities do
  use Ecto.Migration

  def change do
    create table(:content_entities) do
      add :content_id, references(:contents, on_delete: :delete_all), null: false
      add :model_id, :string, null: false        # "bert_ner", "xlm_roberta_ner", "finbert_ner"
      add :model_version, :string, null: false   # Model version for tracking

      # Entity information
      add :entity_text, :string, null: false     # Raw extracted text: "Canada", "Tesla Inc"
      add :entity_type, :string, null: false     # "ORG", "PERSON", "LOC", "PRODUCT", etc.
      add :entity_subtype, :string              # "company", "government", "industry", etc.

      # Position and context
      add :start_char, :integer                  # Character position in text
      add :end_char, :integer
      add :context_snippet, :text               # Surrounding text for context

      # Classification
      add :confidence, :float, null: false       # Model confidence 0.0-1.0
      add :is_target, :boolean, default: false   # Is this entity a target of sentiment?
      add :sentiment_toward, :string            # If target: "positive", "negative", "neutral"

      # Metadata
      add :meta, :map, default: %{}             # Model-specific metadata, all raw output

      timestamps(type: :utc_datetime)
    end

    # Indexes for common queries
    create index(:content_entities, [:content_id])
    create index(:content_entities, [:entity_text])
    create index(:content_entities, [:entity_type])
    create index(:content_entities, [:model_id])
    create index(:content_entities, [:is_target])

    # Composite index for entity lookup across content
    create index(:content_entities, [:entity_text, :entity_type, :content_id])

    # Time-based analysis
    create index(:content_entities, [:inserted_at])
  end
end
```

**Example Data**:
```elixir
# Content ID 2: "Canada was caught, red handed, putting up a fraudulent advertisement..."

# Row 1 - bert_ner model
%ContentEntity{
  content_id: 2,
  model_id: "bert_ner",
  model_version: "dslim/bert-base-NER",
  entity_text: "Canada",
  entity_type: "LOC",
  entity_subtype: "country",
  start_char: 0,
  end_char: 6,
  context_snippet: "Canada was caught, red handed",
  confidence: 0.98,
  is_target: true,
  sentiment_toward: "negative",
  meta: %{
    "raw_label" => "B-LOC",
    "score" => 0.9845,
    "word" => "Canada"
  }
}

# Row 2 - xlm_roberta_ner model (same entity, different model)
%ContentEntity{
  content_id: 2,
  model_id: "xlm_roberta_ner",
  model_version: "xlm-roberta-large-finetuned-conll03-english",
  entity_text: "Canada",
  entity_type: "ORG",
  entity_subtype: "government",
  start_char: 0,
  end_char: 6,
  confidence: 0.95,
  is_target: true,
  sentiment_toward: "negative",
  meta: %{...}
}
```

### Option 2: Industry/Sector Mapping Table

**Purpose**: Map entities to industries and business sectors for trading strategy

**Schema**:
```elixir
create table(:entity_industries) do
  add :entity_text, :string, null: false      # "Tesla", "Canada", "Federal Reserve"
  add :entity_type, :string, null: false      # "company", "country", "organization"

  # Industry classification (can have multiple)
  add :primary_industry, :string             # "automotive", "government", "finance"
  add :secondary_industries, {:array, :string}, default: []
  add :business_sectors, {:array, :string}, default: []  # "tech", "manufacturing", "energy"

  # Stock market relevance
  add :ticker_symbols, {:array, :string}, default: []    # ["TSLA"], []
  add :affected_tickers, {:array, :string}, default: []  # Indirect effects

  # Metadata
  add :classification_source, :string        # "manual", "auto", "wikipedia", etc.
  add :confidence, :float
  add :meta, :map, default: %{}

  timestamps(type: :utc_datetime)
end

create unique_index(:entity_industries, [:entity_text, :entity_type])
```

**Example Data**:
```elixir
# Canada entity -> industries
%EntityIndustry{
  entity_text: "Canada",
  entity_type: "country",
  primary_industry: "government",
  secondary_industries: ["international_trade", "diplomacy"],
  business_sectors: ["trade", "lumber", "energy", "automotive"],
  ticker_symbols: [],
  affected_tickers: ["EWC", "^GSPTSE"],  # iShares Canada ETF, TSX Composite
  classification_source: "manual",
  confidence: 1.0
}

# Tesla entity -> industries
%EntityIndustry{
  entity_text: "Tesla",
  entity_type: "company",
  primary_industry: "automotive",
  secondary_industries: ["technology", "energy", "manufacturing"],
  business_sectors: ["electric_vehicles", "renewable_energy", "tech"],
  ticker_symbols: ["TSLA"],
  affected_tickers: ["F", "GM", "NIO"],  # Competitors
  classification_source: "manual",
  confidence: 1.0
}
```

### Option 3: JSONB in Content Table (Not Recommended)

**Why Not**: Same reasons as Issue #18 - difficult to query, no normalization, performance issues

---

## Named Entity Recognition (NER) Models

### Recommended Initial Models (3-4 models)

#### 1. BERT-Base NER (General Entities)
- **Model**: `dslim/bert-base-NER`
- **Strengths**: Fast, accurate for basic entities (PER, ORG, LOC, MISC)
- **Use Case**: Baseline entity extraction
- **Performance**: ~50-100ms per text

#### 2. XLM-RoBERTa NER (Organizations Focus)
- **Model**: `xlm-roberta-large-finetuned-conll03-english`
- **Strengths**: Better at organizations, governments, institutions
- **Use Case**: Identifying companies and government entities
- **Performance**: ~150-250ms per text

#### 3. FinBERT NER or Financial NER (Optional - if exists)
- **Model**: TBD (need to research financial-specific NER models)
- **Strengths**: Trained on financial text, better for company names
- **Use Case**: Extracting company names, financial institutions
- **Performance**: TBD

#### 4. spaCy NER (Alternative/Comparison)
- **Model**: `en_core_web_lg` or `en_core_web_trf`
- **Strengths**: Fast, well-established, good baseline
- **Use Case**: Validation and comparison
- **Performance**: ~20-50ms per text

### Entity Types to Extract

**Standard NER Types**:
- `PER` - Person (Elon Musk, Joe Biden)
- `ORG` - Organization (Tesla, Federal Reserve, Canadian Government)
- `LOC` - Location (Canada, China, Mexico)
- `MISC` - Miscellaneous (products, events)

**Custom Subtypes** (post-processing):
- `company` - Business entities (Tesla, Amazon, GM)
- `government` - Government bodies (Canada, Federal Reserve, SEC)
- `industry` - Industry sectors (automotive, tech, energy)
- `product` - Products (Cybertruck, iPhone)
- `person_role` - People in official capacity (CEO, President)

---

## Target Identification Logic

**How do we determine if an entity is a "target"?**

### Approach 1: Sentiment-Entity Correlation (Recommended for MVP)

**Logic**: If content is negative AND entity is mentioned, likely the entity is targeted

**Simple Rule**:
```python
# After running sentiment models (Issue #18) and NER models
if overall_sentiment == "negative" and entity_mentioned:
    entity.is_target = True
    entity.sentiment_toward = "negative"
```

**Refinement** (later):
- Analyze proximity of entity to negative words
- Detect attack keywords near entity ("fraud", "cheated", "terrible")
- Compare entity mentions across positive vs negative content

### Approach 2: Aspect-Based Sentiment Analysis (Future Enhancement)

**Models**:
- `yangheng/deberta-v3-base-absa-v1.1`
- Custom fine-tuned models on political/business text

**Capability**: Extract sentiment toward specific entities within mixed-sentiment text

**Example**:
```
Text: "China is terrible on trade, but I love the Chinese people"
Entity-Sentiment:
  - China (government): negative
  - Chinese people: positive
```

**When to implement**: After collecting data from Approach 1, if we need finer granularity

---

## Python Multi-Model Entity Extraction

### Script: `priv/ml/extract_entities.py`

**Philosophy**: Same as sentiment classification - run ALL models, collect ALL entities

```python
#!/usr/bin/env python3
"""
Multi-Model Entity Extraction Script
Runs multiple NER models and outputs all entities in JSON format.
"""

import json
import sys
import time
from transformers import pipeline, AutoTokenizer, AutoModelForTokenClassification
import torch

# Model configurations
MODELS = {
    "bert_ner": {
        "model": "dslim/bert-base-NER",
        "aggregation_strategy": "simple"
    },
    "xlm_roberta_ner": {
        "model": "xlm-roberta-large-finetuned-conll03-english",
        "aggregation_strategy": "simple"
    }
    # Add more models as needed
}

def load_models():
    """Load all NER models."""
    models = {}
    device = 0 if torch.cuda.is_available() else -1

    for model_id, config in MODELS.items():
        print(f"Loading {model_id}...", file=sys.stderr)
        models[model_id] = pipeline(
            "ner",
            model=config["model"],
            aggregation_strategy=config["aggregation_strategy"],
            device=device
        )

    return models

def extract_entities(models, text, content_id=None):
    """Extract entities using all models."""
    results = []

    for model_id, model in models.items():
        start_time = time.time()

        try:
            # Run NER model
            entities = model(text)
            latency_ms = int((time.time() - start_time) * 1000)

            # Process each entity
            for entity in entities:
                # Calculate context snippet (±30 chars around entity)
                start = max(0, entity['start'] - 30)
                end = min(len(text), entity['end'] + 30)
                context = text[start:end]

                results.append({
                    "content_id": content_id,
                    "model_id": model_id,
                    "model_version": MODELS[model_id]["model"],
                    "entity_text": entity['word'],
                    "entity_type": entity['entity_group'],
                    "start_char": entity['start'],
                    "end_char": entity['end'],
                    "context_snippet": context,
                    "confidence": round(entity['score'], 4),
                    "meta": {
                        "processing": {
                            "latency_ms": latency_ms,
                            "timestamp": time.strftime("%Y-%m-%dT%H:%M:%SZ", time.gmtime())
                        },
                        "raw_output": entity
                    }
                })

        except Exception as e:
            print(f"Error with {model_id}: {str(e)}", file=sys.stderr)
            continue

    return results

def main():
    # Read input text from stdin or file
    text = sys.stdin.read().strip()

    if not text:
        print(json.dumps({"error": "No input text provided"}))
        sys.exit(1)

    # Load models
    models = load_models()

    # Extract entities
    entities = extract_entities(models, text)

    # Output JSON
    print(json.dumps({
        "entities": entities,
        "total_entities": len(entities),
        "models_used": list(MODELS.keys())
    }, indent=2))

if __name__ == "__main__":
    main()
```

---

## Elixir Integration

### Module: `lib/volfefe_machine/intelligence/entity_extractor.ex`

```elixir
defmodule VolfefeMachine.Intelligence.EntityExtractor do
  @moduledoc """
  Extracts entities from content using multiple NER models.
  Stores all entities for later analysis.
  """

  alias VolfefeMachine.{Content, Repo}
  alias VolfefeMachine.Intelligence.ContentEntity

  @python_script "priv/ml/extract_entities.py"

  def extract_and_store(content) do
    with {:ok, text} <- validate_text(content),
         {:ok, entities_json} <- run_entity_extraction(text),
         {:ok, entities} <- parse_entities(entities_json),
         {:ok, saved} <- save_entities(entities, content.id) do
      {:ok, saved}
    else
      error -> error
    end
  end

  defp validate_text(%{text: text}) when is_binary(text) do
    case String.trim(text) do
      "" -> {:error, :no_text}
      trimmed -> {:ok, trimmed}
    end
  end
  defp validate_text(_), do: {:error, :no_text}

  defp run_entity_extraction(text) do
    # Pass text directly via stdin using input: parameter
    # Python returns entities without content_id; we inject it after parsing
    case System.cmd("python3", [@python_script],
                    cd: File.cwd!(),
                    stderr_to_stdout: true,
                    input: text) do
      {output, 0} -> {:ok, output}
      {error, _} -> {:error, {:python_error, error}}
    end
  end

  defp parse_entities(json_string) do
    case Jason.decode(json_string) do
      {:ok, %{"entities" => entities}} -> {:ok, entities}
      {:ok, %{"error" => error}} -> {:error, {:extraction_error, error}}
      {:error, reason} -> {:error, {:json_parse_error, reason}}
    end
  end

  defp save_entities(entities, content_id) do
    # Insert all entities from all models
    # Inject content_id into each entity before building changeset
    entities
    |> Enum.map(&build_entity_changeset(&1, content_id))
    |> Enum.reduce_while({:ok, []}, fn changeset, {:ok, acc} ->
      case Repo.insert(changeset) do
        {:ok, entity} -> {:cont, {:ok, [entity | acc]}}
        {:error, reason} -> {:halt, {:error, reason}}
      end
    end)
  end

  defp build_entity_changeset(entity_data, content_id) do
    # Inject content_id from Elixir context (not from Python output)
    ContentEntity.changeset(%ContentEntity{}, %{
      content_id: content_id,
      model_id: entity_data["model_id"],
      model_version: entity_data["model_version"],
      entity_text: entity_data["entity_text"],
      entity_type: entity_data["entity_type"],
      start_char: entity_data["start_char"],
      end_char: entity_data["end_char"],
      context_snippet: entity_data["context_snippet"],
      confidence: entity_data["confidence"],
      meta: entity_data["meta"]
    })
  end

  # Query functions for analysis

  def entities_for_content(content_id) do
    ContentEntity
    |> where([e], e.content_id == ^content_id)
    |> order_by([e], [desc: e.confidence])
    |> Repo.all()
  end

  def find_entity_mentions(entity_text) do
    ContentEntity
    |> where([e], e.entity_text == ^entity_text)
    |> preload(:content)
    |> order_by([e], desc: e.inserted_at)
    |> Repo.all()
  end

  def entity_frequency(limit \\ 20) do
    # Top mentioned entities
    ContentEntity
    |> group_by([e], e.entity_text)
    |> select([e], {e.entity_text, count(e.id)})
    |> order_by([e], desc: count(e.id))
    |> limit(^limit)
    |> Repo.all()
  end

  def entities_by_type(type) do
    ContentEntity
    |> where([e], e.entity_type == ^type)
    |> group_by([e], e.entity_text)
    |> select([e], {e.entity_text, count(e.id)})
    |> order_by([e], desc: count(e.id))
    |> Repo.all()
  end
end
```

### Schema: `lib/volfefe_machine/intelligence/content_entity.ex`

```elixir
defmodule VolfefeMachine.Intelligence.ContentEntity do
  use Ecto.Schema
  import Ecto.Changeset

  schema "content_entities" do
    belongs_to :content, VolfefeMachine.Content

    field :model_id, :string
    field :model_version, :string
    field :entity_text, :string
    field :entity_type, :string
    field :entity_subtype, :string
    field :start_char, :integer
    field :end_char, :integer
    field :context_snippet, :string
    field :confidence, :float
    field :is_target, :boolean, default: false
    field :sentiment_toward, :string
    field :meta, :map

    timestamps(type: :utc_datetime)
  end

  def changeset(entity, attrs) do
    entity
    |> cast(attrs, [
      :content_id, :model_id, :model_version, :entity_text, :entity_type,
      :entity_subtype, :start_char, :end_char, :context_snippet, :confidence,
      :is_target, :sentiment_toward, :meta
    ])
    |> validate_required([
      :content_id, :model_id, :model_version, :entity_text, :entity_type, :confidence
    ])
    |> foreign_key_constraint(:content_id)
  end
end
```

---

## Integration with Issue #18 (Multi-Model Sentiment)

### Workflow: Sentiment → Entities → Correlation

```elixir
defmodule VolfefeMachine.Intelligence.Analyzer do
  @moduledoc """
  Coordinates sentiment analysis (Issue #18) with entity extraction (Issue #19)
  to identify targets and their sentiment correlation.
  """

  alias VolfefeMachine.Intelligence.{Classifier, EntityExtractor}

  def analyze_content(content) do
    # Step 1: Run all sentiment models (Issue #18)
    {:ok, classifications} = Classifier.classify_all_models(content)

    # Step 2: Run all entity extraction models (Issue #19)
    {:ok, entities} = EntityExtractor.extract_and_store(content)

    # Step 3: Correlate sentiment with entities
    {:ok, targets} = identify_targets(classifications, entities)

    {:ok, %{
      classifications: classifications,
      entities: entities,
      targets: targets
    }}
  end

  defp identify_targets(classifications, entities) do
    # Simple MVP logic: if overall negative, entities are targets
    overall_sentiment = determine_consensus_sentiment(classifications)

    if overall_sentiment == "negative" do
      # Mark all high-confidence entities as targets
      entities
      |> Enum.filter(& &1.confidence >= 0.7)
      |> Enum.map(&mark_as_target(&1, "negative"))
    else
      {:ok, []}
    end
  end

  defp determine_consensus_sentiment(classifications) do
    # Use majority vote or weighted average
    # This is simplified - real logic would be more sophisticated
    classifications
    |> Enum.map(& &1.sentiment)
    |> Enum.frequencies()
    |> Enum.max_by(fn {_sentiment, count} -> count end)
    |> elem(0)
  end

  defp mark_as_target(entity, sentiment) do
    # Update entity as target
    entity
    |> Ecto.Changeset.change(%{
      is_target: true,
      sentiment_toward: sentiment
    })
    |> Repo.update!()
  end
end
```

---

## Analysis Queries

### Query 1: Top Targeted Entities (Negative Sentiment)

```elixir
def top_negative_targets(limit \\ 10) do
  ContentEntity
  |> where([e], e.is_target == true and e.sentiment_toward == "negative")
  |> group_by([e], e.entity_text)
  |> select([e], {e.entity_text, count(e.id)})
  |> order_by([e], desc: count(e.id))
  |> limit(^limit)
  |> Repo.all()
end

# Example output:
# [
#   {"Canada", 5},
#   {"China", 3},
#   {"Federal Reserve", 2}
# ]
```

### Query 2: Entity Mention Timeline

```elixir
def entity_timeline(entity_text) do
  from(e in ContentEntity,
    join: c in assoc(e, :content),
    where: e.entity_text == ^entity_text,
    select: %{
      date: fragment("date_trunc('day', ?)", c.inserted_at),
      mentions: count(e.id),
      avg_sentiment: avg(
        fragment("CASE
                    WHEN ? = 'negative' THEN -1.0
                    WHEN ? = 'positive' THEN 1.0
                    ELSE 0.0
                  END",
                  e.sentiment_toward, e.sentiment_toward)
      )
    },
    group_by: fragment("date_trunc('day', ?)", c.inserted_at),
    order_by: fragment("date_trunc('day', ?)", c.inserted_at)
  )
  |> Repo.all()
end
```

### Query 3: Industry Impact Analysis

```elixir
def industry_sentiment_analysis do
  # Join entities → industries → classifications
  # Requires EntityIndustry table implementation
  from(e in ContentEntity,
    join: ei in EntityIndustry, on: e.entity_text == ei.entity_text,
    join: c in assoc(e, :content),
    join: cl in Classification, on: cl.content_id == c.id,
    where: e.is_target == true,
    group_by: ei.primary_industry,
    select: %{
      industry: ei.primary_industry,
      mentions: count(e.id),
      avg_sentiment: avg(cl.confidence * fragment("CASE
                                                      WHEN cl.sentiment = 'negative' THEN -1
                                                      WHEN cl.sentiment = 'positive' THEN 1
                                                      ELSE 0
                                                    END")),
      affected_tickers: fragment("array_agg(DISTINCT ?)", ei.ticker_symbols)
    }
  )
  |> Repo.all()
end
```

---

## Implementation Plan

### Phase 1: Basic Entity Extraction (4-6 hours)
1. ✅ Create `content_entities` table migration
2. ✅ Create `ContentEntity` schema
3. ✅ Write `priv/ml/extract_entities.py` with 2 NER models
4. ✅ Create `EntityExtractor` module
5. ✅ Test on 10-20 posts
6. ✅ Verify entities stored correctly

### Phase 2: Target Identification Logic (3-4 hours)
1. ✅ Integrate with sentiment classifications (Issue #18)
2. ✅ Implement simple target detection (negative sentiment → entities are targets)
3. ✅ Add `is_target` and `sentiment_toward` fields
4. ✅ Test correlation accuracy on known examples
5. ✅ Create analysis queries

### Phase 3: Industry Mapping (Optional - 4-6 hours)
1. ✅ Create `entity_industries` table
2. ✅ Manually map 20-30 common entities to industries/tickers
3. ✅ Create industry impact queries
4. ⏸️ Consider automation (Wikipedia API, financial data APIs)

### Phase 4: Data Collection & Analysis (Ongoing)
1. ✅ Run entity extraction on all existing content (~87 posts)
2. ✅ Collect 100-1000 posts with entities
3. ✅ Analyze patterns:
   - Which entities are mentioned most?
   - Which industries are targeted most?
   - Correlation between entity type and sentiment?
   - NER model agreement/disagreement rates?
4. ✅ Refine target identification logic based on data

**Total Estimated Time**: 12-16 hours (excluding ongoing data collection)

---

## Open Questions & Decisions Needed

### 1. Schema Choice
- **Option 1**: Separate `content_entities` table (recommended)
- **Option 2**: JSONB in content table (not recommended)
- **Decision needed**: Approve Option 1?

### 2. Initial NER Models
- **Proposed**: BERT-NER + XLM-RoBERTa NER (2 models)
- **Optional**: Add spaCy or FinBERT-NER
- **Decision needed**: Start with 2 or 3 models?

### 3. Industry Mapping Strategy
- **Option A**: Manual mapping (20-30 entities, ~2 hours)
- **Option B**: Automated via Wikipedia API (more complex)
- **Option C**: Skip for MVP, focus on entities only
- **Decision needed**: Which approach?

### 4. Target Identification Complexity
- **MVP**: Simple rule (negative sentiment → entities are targets)
- **Enhanced**: Aspect-based sentiment analysis (future)
- **Decision needed**: MVP sufficient to start?

### 5. Integration with Issue #18
- **Sequential**: First sentiment (Issue #18), then entities (Issue #19)
- **Parallel**: Run both simultaneously
- **Decision needed**: Wait for Issue #18 completion or start in parallel?

---

## Success Criteria

### Functional Requirements
✅ Extract entities from all content using multiple NER models
✅ Store all entities with full metadata (model, confidence, position)
✅ Identify which entities are targets of negative sentiment
✅ Query entities by type, frequency, timeline
✅ Correlate entities with industries/tickers (if implemented)

### Quality Requirements
✅ Entity extraction accuracy >80% (manual validation)
✅ Target identification accuracy >70% (on obvious examples)
✅ Entity extraction latency <500ms per content
✅ Store 100% of entity data for later analysis

### Business Requirements
✅ Answer: "Which companies/industries did Trump target this week?"
✅ Answer: "How often is Tesla mentioned in negative context?"
✅ Answer: "Which sectors are most frequently attacked?"
✅ Enable trading strategy: negative mention of Canada → short Canadian ETF

---

## Dependencies

**Requires**:
- ✅ Python 3.x with transformers library
- ✅ PostgreSQL with JSONB support
- ✅ Elixir/Phoenix with Ecto
- ✅ Issue #18 (sentiment) completed or in progress

**Builds Upon**:
- Issue #18: Multi-model sentiment classification provides the "negative" signal
- Issue #19: Entity extraction provides the "who/what" is targeted

**Future Enhancements**:
- Aspect-based sentiment analysis
- Real-time industry impact dashboard
- Stock ticker alert system
- Historical entity-stock correlation analysis
