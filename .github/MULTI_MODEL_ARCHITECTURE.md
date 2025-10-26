# Multi-Model Sentiment Classification Architecture

**Issue Type**: Architecture Design / Research
**Priority**: High
**Estimated Effort**: 15-20 hours (research + implementation)
**Created**: 2025-10-26

---

## Problem Statement

### Current Limitation: One Model, One Context

**Current Architecture**:
- Single model (FinBERT) for all content
- One classification per content item
- No context awareness
- No model flexibility

**Discovered Issues**:
1. FinBERT excellent for financial sentiment, terrible for political attacks
2. DistilBERT excellent for general sentiment, but no financial nuance
3. Twitter-RoBERTa good for social media, but lacks domain expertise
4. **Each model has different strengths for different contexts**

**Real-World Example**:
> "Ford and GM UP BIG on Tariffs... Thank you President Trump!"

**What we need**:
- **FinBERT**: Analyze financial impact on Ford/GM stock sentiment
- **DistilBERT**: Overall political message sentiment
- **Twitter-RoBERTa**: Social media virality/tone
- **Combined**: Rich, multi-dimensional sentiment analysis

---

## Vision: Context-Aware Multi-Model System

### Core Principles

1. **Multiple Models, Multiple Perspectives**
   - Store classifications from multiple models per content
   - Each model provides different lens of analysis
   - Richer data for trading decisions

2. **Context Detection & Routing**
   - Automatically detect content type (financial, political, social)
   - Route to appropriate model(s)
   - Use different models for different insights

3. **Hot-Swappable Models**
   - Easy to add/remove models without code changes
   - A/B testing capability
   - Model versioning and comparison

4. **Ensemble Intelligence**
   - Combine results from multiple models
   - Weighted voting based on context and confidence
   - Detect disagreements as signals

---

## Use Cases

### Use Case 1: Financial Content

**Post**: "Tesla Q4 earnings beat expectations! Stock up 15% after-hours. Great quarter!"

**Multi-Model Analysis**:
- **FinBERT** (primary): positive (0.98) - "earnings beat" = strong buy signal
- **DistilBERT** (secondary): positive (0.95) - general positive tone
- **Twitter-RoBERTa**: positive (0.92) - social media excitement

**Trading Signal**: STRONG BUY - all models agree, FinBERT highly confident on financial context

---

### Use Case 2: Political Attack with Economic Impact

**Post**: "CANADA CHEATED! Caught red handed with fraudulent tariff ads. Increasing tariffs 10% NOW!"

**Multi-Model Analysis**:
- **FinBERT**: neutral (0.99) - sees "tariff" as economic policy (MISSES the attack)
- **DistilBERT**: negative (0.97) - correctly identifies attack tone
- **Twitter-RoBERTa**: negative (0.75) - social media anger

**Combined Insight**:
- Sentiment: NEGATIVE (DistilBERT + Twitter agree, FinBERT wrong)
- Economic Impact: TARIFF INCREASE detected by FinBERT
- Trading Signal: Sell Canadian stocks, buy tariff beneficiaries

**Value**: Using FinBERT for keyword extraction ("tariff increase") even though sentiment is wrong

---

### Use Case 3: Mixed Financial/Political Content

**Post**: "The Fed is DESTROYING our economy with ridiculous interest rates! Inflation is a SCAM!"

**Multi-Model Analysis**:
- **FinBERT**: negative (0.85) - "Fed", "interest rates", "inflation" = financial concern
- **DistilBERT**: negative (0.92) - strong negative sentiment
- **Twitter-RoBERTa**: negative (0.88) - angry tone

**Combined Insight**:
- All models agree: NEGATIVE
- Financial domain detected by FinBERT keyword analysis
- Trading Signal: Possible Fed policy criticism → monitor for market reactions

---

### Use Case 4: Model Disagreement as Signal

**Post**: "Stock market at all-time highs but fake news media won't report it!"

**Multi-Model Analysis**:
- **FinBERT**: positive (0.95) - "stock market all-time highs" = bullish
- **DistilBERT**: mixed/neutral (0.55) - detects criticism ("fake news")
- **Twitter-RoBERTa**: negative (0.70) - complaint/attack tone

**Combined Insight**:
- **Disagreement detected** → high uncertainty
- Financial: Positive (market highs)
- Political: Negative (media attack)
- Trading Signal: HOLD - mixed sentiment, use caution

**Value**: Model disagreement flags complex, nuanced posts requiring human review

---

## Proposed Architecture

### 1. Model Registry System

**Concept**: Centralized registry of available models with metadata

```elixir
# config/models.exs
config :volfefe_machine, :sentiment_models, [
  %{
    id: :finbert,
    name: "FinBERT",
    model_path: "yiyanghkust/finbert-tone",
    version: "v1.0",
    strengths: [:financial, :earnings, :markets],
    weaknesses: [:political_attacks, :social_media],
    priority: :high_for_financial,
    enabled: true
  },
  %{
    id: :distilbert,
    name: "DistilBERT SST-2",
    model_path: "distilbert-base-uncased-finetuned-sst-2-english",
    version: "v1.0",
    strengths: [:general_sentiment, :political, :attacks],
    weaknesses: [:financial_nuance],
    priority: :high_for_general,
    enabled: true
  },
  %{
    id: :twitter_roberta,
    name: "Twitter-RoBERTa",
    model_path: "cardiffnlp/twitter-roberta-base-sentiment-latest",
    version: "v1.0",
    strengths: [:social_media, :informal_language, :virality],
    weaknesses: [:formal_text, :financial],
    priority: :medium,
    enabled: false  # Can enable later
  }
]
```

**Benefits**:
- ✅ Add/remove models via configuration
- ✅ Enable/disable models without code changes
- ✅ Document model strengths/weaknesses
- ✅ A/B testing by toggling `enabled`

---

### 2. Context Detection System

**Concept**: Analyze content to determine primary context(s)

**Approach 1: Keyword-Based Detection** (Simple, Fast)

```elixir
defmodule VolfefeMachine.Intelligence.ContextDetector do
  @financial_keywords ~w(
    stock market earnings revenue profit loss
    tariff trade fed interest inflation
    dollar euro currency bond yield
    buy sell bullish bearish
  )

  @political_keywords ~w(
    election vote congress senate
    policy law regulation executive
    democrat republican liberal conservative
    fraud cheat rigged corrupt
  )

  @social_keywords ~w(
    RT @ # trending viral
    like share retweet follow
  )

  def detect_contexts(text) do
    text_lower = String.downcase(text)

    %{
      financial: count_keywords(text_lower, @financial_keywords),
      political: count_keywords(text_lower, @political_keywords),
      social: count_keywords(text_lower, @social_keywords)
    }
  end
end
```

**Approach 2: Lightweight Classifier** (More Accurate, Slower)

```python
# Use small, fast model for context detection
context_classifier = pipeline(
    "zero-shot-classification",
    model="facebook/bart-large-mnli"
)

contexts = context_classifier(
    text,
    candidate_labels=["financial", "political", "social media", "general"]
)
# Returns: {"financial": 0.8, "political": 0.6, "social media": 0.3, "general": 0.1}
```

**Output**:
```json
{
  "contexts": {
    "financial": 0.85,
    "political": 0.65,
    "social": 0.20
  },
  "primary_context": "financial",
  "secondary_context": "political"
}
```

---

### 3. Smart Model Routing

**Concept**: Route content to appropriate models based on detected context

**Routing Strategy**:

| Detected Context | Models to Use | Priority |
|-----------------|---------------|----------|
| **Financial** (>0.7) | FinBERT (primary), DistilBERT (secondary) | FinBERT weighted 0.7, DistilBERT 0.3 |
| **Political** (>0.7) | DistilBERT (primary), Twitter-RoBERTa (secondary) | DistilBERT 0.7, Twitter 0.3 |
| **Social Media** (>0.7) | Twitter-RoBERTa (primary), DistilBERT (secondary) | Twitter 0.7, DistilBERT 0.3 |
| **Mixed** (multiple >0.5) | ALL models | Ensemble voting |
| **Uncertain** (all <0.5) | DistilBERT only | General sentiment fallback |

**Example**:
```elixir
# Content with financial=0.85, political=0.65
models_to_use = [
  {:finbert, priority: :high},      # Financial context detected
  {:distilbert, priority: :medium}   # Political context also present
]
```

---

### 4. Multi-Model Classification Storage

**Option A: One Classification Per Model** (Recommended)

**New Schema**: Classifications table updated to support multiple classifications per content

```elixir
# Current schema (one classification per content)
unique_index(:classifications, [:content_id])

# New schema (multiple classifications per content, one per model)
create unique_index(:classifications, [:content_id, :model_id])
```

**Benefits**:
- ✅ Store full results from each model
- ✅ Compare model performance over time
- ✅ A/B testing built-in
- ✅ Can reprocess with new models without losing old data

**Example Data**:
```
content_id | model_id       | sentiment | confidence | meta
-----------+----------------+-----------+------------+------
1          | finbert        | neutral   | 0.9989     | {...}
1          | distilbert     | positive  | 0.9995     | {...}
1          | twitter_roberta| neutral   | 0.4827     | {...}
```

---

**Option B: Aggregate Classification with Model Details in Meta** (Simpler)

**Keep current schema**, store all model results in `meta.models`:

```json
{
  "sentiment": "positive",        // Ensemble result
  "confidence": 0.95,             // Weighted average
  "model_version": "ensemble-v1.0",
  "meta": {
    "ensemble": {
      "method": "weighted_vote",
      "primary_context": "financial",
      "agreement": true
    },
    "models": {
      "finbert": {
        "sentiment": "positive",
        "confidence": 0.98,
        "weight": 0.7,
        "latency_ms": 2500
      },
      "distilbert": {
        "sentiment": "positive",
        "confidence": 0.95,
        "weight": 0.3,
        "latency_ms": 50
      }
    },
    "context_detection": {
      "financial": 0.85,
      "political": 0.20
    }
  }
}
```

**Benefits**:
- ✅ No schema changes
- ✅ All model data in one place
- ✅ Ensemble result + individual results

**Drawbacks**:
- ⚠️ Can't query individual model results easily
- ⚠️ JSONB queries more complex

---

### 5. Ensemble Aggregation Strategies

**Strategy 1: Weighted Voting** (Context-Aware)

```elixir
def ensemble_vote(model_results, context_scores) do
  # Weight by context match
  weighted_results =
    for {model_id, result} <- model_results do
      model_config = get_model_config(model_id)
      context_match = calculate_context_match(model_config.strengths, context_scores)

      weight = context_match * result.confidence

      {model_id, result, weight}
    end

  # Weighted majority vote
  total_weight = Enum.sum(Enum.map(weighted_results, fn {_, _, w} -> w end))

  sentiment_weights = %{
    "positive" => calculate_weight(weighted_results, "positive"),
    "negative" => calculate_weight(weighted_results, "negative"),
    "neutral" => calculate_weight(weighted_results, "neutral")
  }

  {winning_sentiment, confidence} =
    sentiment_weights
    |> Enum.max_by(fn {_, weight} -> weight end)
    |> then(fn {sentiment, weight} -> {sentiment, weight / total_weight} end)

  %{
    sentiment: winning_sentiment,
    confidence: confidence,
    method: "weighted_vote",
    agreement: check_agreement(weighted_results)
  }
end
```

**Example**:
```
Context: Financial (0.85), Political (0.20)

FinBERT:   positive (0.98) × context_match(0.9) × confidence(0.98) = 0.864
DistilBERT: positive (0.95) × context_match(0.3) × confidence(0.95) = 0.271

Total weight = 1.135
Positive weight = 1.135
Final: positive (1.135 / 1.135 = 1.0) with full agreement
```

---

**Strategy 2: Confidence-Based Selection** (Pick Best)

```elixir
def confidence_based(model_results) do
  # Simply pick the model with highest confidence
  {model_id, result} =
    model_results
    |> Enum.max_by(fn {_, result} -> result.confidence end)

  Map.merge(result, %{selected_model: model_id, method: "highest_confidence"})
end
```

---

**Strategy 3: Disagreement Detection** (Flag Uncertainty)

```elixir
def detect_disagreement(model_results) do
  sentiments = Enum.map(model_results, fn {_, r} -> r.sentiment end)
  unique_sentiments = Enum.uniq(sentiments)

  if length(unique_sentiments) > 1 do
    %{
      agreement: false,
      flag: :manual_review_required,
      sentiments: Enum.frequencies(sentiments),
      recommendation: "High uncertainty - multiple models disagree"
    }
  else
    %{
      agreement: true,
      consensus: hd(unique_sentiments)
    }
  end
end
```

---

## Implementation Plan

### Phase 1: Model Registry (2-3 hours)

**Tasks**:
- [ ] Create model configuration system
- [ ] Add model metadata (strengths, weaknesses, enabled)
- [ ] Build model loader with registry support
- [ ] Test hot-swapping models via config

**Deliverables**:
- `config/models.exs` - Model registry
- `lib/intelligence/model_registry.ex` - Model management
- Documentation on adding/removing models

---

### Phase 2: Context Detection (3-4 hours)

**Tasks**:
- [ ] Implement keyword-based context detector
- [ ] Test on 50 sample posts
- [ ] Measure accuracy of context detection
- [ ] Optional: Research zero-shot classifier approach

**Deliverables**:
- `lib/intelligence/context_detector.ex` - Context detection
- Context detection accuracy report
- Keyword lists for financial/political/social

---

### Phase 3: Multi-Model Classification (4-5 hours)

**Tasks**:
- [ ] Design schema changes (Option A or B)
- [ ] Update Python script to support multiple models
- [ ] Implement model routing based on context
- [ ] Store multiple model results

**Deliverables**:
- Migration for multi-model schema
- `priv/ml/classify_multi.py` - Multi-model Python script
- Updated Intelligence context to handle multiple models

---

### Phase 4: Ensemble Aggregation (3-4 hours)

**Tasks**:
- [ ] Implement weighted voting algorithm
- [ ] Implement disagreement detection
- [ ] Create ensemble result from multiple models
- [ ] Test on 50 posts, compare to single-model

**Deliverables**:
- `lib/intelligence/ensemble.ex` - Aggregation logic
- Comparison report: ensemble vs single-model accuracy

---

### Phase 5: Testing & Validation (2-3 hours)

**Tasks**:
- [ ] Reclassify 20 sample posts with multi-model system
- [ ] Compare results to current single-model
- [ ] Measure performance impact (latency)
- [ ] Manual validation of complex cases

**Deliverables**:
- Multi-model test results
- Performance benchmarks
- Validation report

---

## Research Questions (Use Context7 + Sequential)

### Context7: Model Research

**Questions to Investigate**:
1. Are there domain-specific sentiment models for finance?
   - Search: "financial sentiment analysis models huggingface"
   - Alternative to FinBERT?

2. Are there political sentiment models?
   - Search: "political sentiment analysis models"
   - Fine-tuned on political text?

3. What's the state-of-the-art in multi-model sentiment?
   - Search: "ensemble sentiment analysis"
   - Industry best practices?

4. Zero-shot classification for context detection?
   - Search: "zero-shot text classification models"
   - facebook/bart-large-mnli vs alternatives?

---

### Sequential: System Design Thinking

**Analysis Questions**:

1. **Schema Design**: Option A (multiple rows) vs Option B (JSONB meta)?
   - Pros/cons of each approach
   - Query patterns and performance
   - Migration complexity
   - Recommendation with rationale

2. **Ensemble Strategy**: Which aggregation method?
   - Weighted voting vs confidence-based vs hybrid
   - When to use each strategy
   - Recommendation with examples

3. **Performance Impact**: How does multi-model affect speed?
   - Run models in parallel or sequential?
   - Acceptable latency increase?
   - Cost vs benefit analysis

4. **Context Detection Accuracy**: Is keyword-based good enough?
   - Test accuracy on 100 posts
   - When to upgrade to ML-based detection?
   - Recommendation for Phase 3

---

## Success Criteria

### Quality Metrics

✅ **Improved negative detection**: 20-40% negative rate (currently 2%)
✅ **Context-aware accuracy**: Right model for right content type
✅ **Disagreement detection**: Flag uncertain cases for review
✅ **Ensemble confidence**: Higher confidence on agreed cases

### Performance Metrics

✅ **Latency**: <500ms for multi-model (vs 3000ms single FinBERT)
✅ **Parallel processing**: Run models concurrently
✅ **Model flexibility**: Add/remove models via config only

### System Metrics

✅ **Hot-swappable**: No code changes to enable/disable models
✅ **A/B testing**: Easy to compare model versions
✅ **Rich metadata**: Store full results from all models
✅ **Query capability**: Can analyze by model, by context, by agreement

---

## Risks & Mitigations

### Risk 1: Increased Latency

**Risk**: Running 3 models takes 3x time
**Impact**: Slower classification, worse UX

**Mitigation**:
- Run models in parallel (Python multiprocessing)
- Use fast models (DistilBERT 50ms, Twitter-RoBERTa 100ms)
- Skip slow models for simple contexts (don't run FinBERT on pure political posts)

**Estimated Latency**:
- FinBERT only: 3000ms
- DistilBERT only: 50ms
- All 3 parallel: 3000ms (limited by slowest)
- Smart routing: 50-500ms (skip FinBERT when not needed)

---

### Risk 2: Model Disagreement

**Risk**: Models disagree, unclear which is "correct"
**Impact**: Confusion, manual review burden

**Mitigation**:
- Use disagreement as a signal (high uncertainty = useful info)
- Weighted voting based on context gives "best guess"
- Flag for manual review (build validation dataset)
- Long term: Fine-tune ensemble weights based on trading outcomes

---

### Risk 3: Complexity

**Risk**: System becomes too complex to maintain
**Impact**: Hard to debug, slow to iterate

**Mitigation**:
- Clear separation of concerns (registry, detector, router, ensemble)
- Comprehensive testing and documentation
- Start simple (2 models), expand gradually
- Keep single-model option as fallback

---

## Open Questions

1. **Schema Design**: Multiple rows vs JSONB meta?
   - Need to decide before Phase 3

2. **Context Detection Method**: Keywords vs ML classifier?
   - Research in Phase 2

3. **Ensemble Strategy**: Weighted voting vs confidence-based?
   - Test in Phase 4

4. **Performance Optimization**: Run models in parallel?
   - Requires Python multiprocessing or async

5. **Model Selection**: Which models to include initially?
   - FinBERT + DistilBERT confirmed
   - Twitter-RoBERTa optional?

---

## Related Issues

- Issue #13: Phase 2 Audit - Data Quality Concerns
- Model Comparison Results: `docs/MODEL_COMPARISON_ANALYSIS.md`
- Current Implementation: Single-model FinBERT

---

## Next Actions

**Before Implementation**:
1. Review and approve architecture approach
2. Answer open questions (schema design, ensemble strategy)
3. Decide on Phase 1 scope (model registry + context detection)

**After Approval**:
1. Create detailed technical design document
2. Break down into sub-tasks
3. Begin Phase 1 implementation

---

**Created**: 2025-10-26
**Status**: Proposed
**Effort**: 15-20 hours (full implementation)
**Priority**: High (data quality critical for trading)
