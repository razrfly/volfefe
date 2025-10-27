# Phase 3: Multi-Model Enhancement & Analytics

## Issue Type
Enhancement / Feature Request

## Priority
High

## Labels
`enhancement`, `phase-3`, `analytics`, `performance`

## Linked Issues
- Closes remaining work from #16
- Follow-up to #20 (completed)
- Builds on #18 (completed)

---

## Overview

Phase 2.5 Multi-Model Architecture is **98% complete and production-ready**. This issue tracks the remaining features needed to achieve 100% completion and unlock the full potential of our multi-model sentiment classification system.

### Current Status
- ✅ Database schema: 100% complete (261 model classifications, 0 empty fields)
- ✅ Python multi-model script: 98% complete (all metadata captured)
- ✅ Consensus algorithm: 95% complete (weighted voting working)
- ✅ Testing: 98% complete (77 unit + 8 integration tests passing)
- ❌ Query API: **0% complete** (CRITICAL GAP)
- ❌ Analytics: 30% complete
- ❌ Performance optimization: 0% complete

### Impact of Phase 2.5
- **339% improvement** in negative sentiment detection (3.4% → 14.9%)
- **57.5% full model agreement**, 41.4% partial agreement
- **Perfect data quality**: 0 empty metadata fields across 261 records

---

## PRIORITY 1: Critical Missing Features (8-10 hours)

### 1. Model Classifications Query API (2-3 hours) 🔴 **CRITICAL**

**Problem:** We can store model results but cannot retrieve them programmatically. All analysis requires raw SQL.

**Required Functions:**
```elixir
# Add to lib/volfefe_machine/intelligence.ex

@doc """
Get all model classifications for a specific content item.
Returns all 3 model results with full metadata.
"""
def get_model_classifications_by_content(content_id)

@doc """
Get all classifications from a specific model.
Useful for model performance analysis.
"""
def list_model_classifications_by_model(model_id, opts \\ [])

@doc """
Compare results from all models for a content item.
Returns structured comparison with agreements/disagreements.
"""
def compare_model_results(content_id)

@doc """
Get a specific model's classification for content.
"""
def get_model_classification(content_id, model_id)
```

**Acceptance Criteria:**
- [ ] All functions return proper Ecto structs (not raw SQL)
- [ ] Functions handle missing data gracefully
- [ ] Includes preloading of content when needed
- [ ] Comprehensive test coverage for each function

**Estimated Effort:** 2-3 hours

---

### 2. Disagreement Detection System (2-3 hours) 🔴 **HIGH PRIORITY**

**Problem:** Models disagree on 42.5% of content, but we have no system to flag or review these cases.

**Current Data:**
- Full Agreement: 50 cases (57.5%)
- Partial Agreement: 36 cases (41.4%)
- Full Disagreement: 1 case (1.1%)

**Required Functions:**
```elixir
@doc """
Find content where models disagree significantly.
Options:
  - threshold: Minimum agreement rate (default 0.5)
  - sentiment: Filter by consensus sentiment
  - limit: Max results (default 50)
"""
def find_disagreements(opts \\ [])

@doc """
Flag a content item as contentious for human review.
Adds review_flag to consensus classification.
"""
def flag_contentious_content(content_id, reason)

@doc """
Get disagreement statistics across all content.
Returns breakdown by disagreement type and patterns.
"""
def get_disagreement_stats()

@doc """
List all content flagged for manual review.
"""
def list_flagged_content()
```

**Acceptance Criteria:**
- [ ] Can identify partial and full disagreements
- [ ] Tracks common disagreement patterns (e.g., DistilBERT vs FinBERT)
- [ ] Provides actionable review list
- [ ] Includes test coverage for edge cases

**Estimated Effort:** 2-3 hours

---

### 3. Model Performance Analytics (3-4 hours) 🔴 **HIGH PRIORITY**

**Problem:** No way to track model performance, confidence distributions, or accuracy over time.

**Required Functions:**
```elixir
@doc """
Get comprehensive statistics for a model.
Returns sentiment distribution, avg confidence, etc.
"""
def get_model_stats(model_id)

@doc """
Compare performance between two models.
Shows agreement rate, confidence differences.
"""
def compare_model_performance(model_id_1, model_id_2)

@doc """
Get confidence distribution for a model.
Useful for calibration analysis.
"""
def get_confidence_distribution(model_id, opts \\ [])

@doc """
Track model accuracy over time (requires ground truth).
Returns time-series data for dashboards.
"""
def get_model_accuracy_timeline(model_id, opts \\ [])

@doc """
Get overall system health metrics.
Includes agreement rates, coverage, latency stats.
"""
def get_system_health_metrics()
```

**Acceptance Criteria:**
- [ ] Returns structured data suitable for dashboards
- [ ] Handles time-based queries efficiently
- [ ] Includes aggregation for performance
- [ ] Test coverage for all metrics

**Estimated Effort:** 3-4 hours

---

## PRIORITY 2: Performance Optimizations (8-12 hours)

### 4. Parallel Model Execution (4-5 hours) 🟡

**Current State:** Models run sequentially (2-5 second latency)

**Target:** Parallel execution (0.5-1.5 second latency) - **60-70% improvement**

**Implementation:**
```python
# priv/ml/classify_multi_model.py

import multiprocessing
from concurrent.futures import ProcessPoolExecutor

def classify_parallel(text, models):
    """
    Run all models in parallel using ProcessPoolExecutor.
    Reduces latency from sum of models to max of models.
    """
    with ProcessPoolExecutor(max_workers=3) as executor:
        futures = {executor.submit(classify_with_model, text, model): model
                   for model in models}
        results = []
        for future in concurrent.futures.as_completed(futures):
            results.append(future.result())
    return results
```

**Acceptance Criteria:**
- [ ] All 3 models run in parallel
- [ ] Latency reduced by 60%+ in benchmarks
- [ ] Error handling for individual model failures
- [ ] Graceful fallback to sequential if parallel fails
- [ ] Memory usage remains acceptable

**Estimated Effort:** 4-5 hours

---

### 5. Enhanced Consensus Algorithm (4-5 hours) 🟡

**Current:** Simple weighted voting (v1.0)

**Target:** Smart consensus with disagreement handling (v2.0)

**Features:**
```elixir
# lib/volfefe_machine/intelligence/consensus.ex

@doc """
Consensus v2.0 with disagreement-aware weighting.

Improvements over v1.0:
- Penalize low-confidence votes
- Boost votes when models agree
- Flag high-uncertainty cases
- Track consensus quality metrics
"""
def calculate_v2(model_results, opts \\ [])

@doc """
Compare different consensus strategies on historical data.
Used for A/B testing and optimization.
"""
def compare_consensus_methods(content_ids, methods)

@doc """
Learn optimal weights from labeled data.
Adjust model weights based on accuracy.
"""
def optimize_weights(labeled_dataset)
```

**Acceptance Criteria:**
- [ ] Backward compatible with v1.0
- [ ] Measurably improves consensus quality
- [ ] Includes confidence calibration
- [ ] A/B testing framework functional

**Estimated Effort:** 4-5 hours

---

### 6. Caching & Optimization (2-3 hours) 🟡

**Problem:** Re-classifying same content loads models every time

**Solution:**
```elixir
# Add to model_classifications table
ALTER TABLE model_classifications ADD COLUMN
  cache_hit BOOLEAN DEFAULT FALSE,
  cached_from_id BIGINT REFERENCES model_classifications(id);

# Implement content hash-based caching
def classify_with_cache(text) do
  text_hash = hash_text(text)

  case get_cached_result(text_hash) do
    {:ok, result} -> {:ok, result, cache_hit: true}
    :miss ->
      result = classify_fresh(text)
      cache_result(text_hash, result)
      {:ok, result, cache_hit: false}
  end
end
```

**Acceptance Criteria:**
- [ ] Cache based on content text hash
- [ ] Configurable TTL for cache entries
- [ ] Track cache hit rate
- [ ] 90%+ latency reduction on cache hits

**Estimated Effort:** 2-3 hours

---

## PRIORITY 3: Advanced Features (20-30 hours)

### 7. Context Detection & Smart Routing (12-15 hours) 🟢

**From Original Issue #16 - Deferred to Phase 3**

**Goal:** Detect content type and adjust model weights dynamically

**Implementation:**

**Step 1: Keyword-Based Context Detection (4-5 hours)**
```elixir
defmodule VolfefeMachine.Intelligence.ContextDetector do
  @financial_keywords ~w(market stock earnings profit revenue GDP trade tariff)
  @political_keywords ~w(president congress election vote policy law bill)
  @social_keywords ~w(people community support protest movement)

  @doc """
  Detect content context(s) with confidence scores.
  Returns: %{financial: 0.85, political: 0.65, social: 0.20}
  """
  def detect_context(text)

  @doc """
  Adjust model weights based on detected context.
  Financial: FinBERT weight increases
  Political: DistilBERT weight increases
  Social: Twitter-RoBERTa weight increases
  """
  def get_context_adjusted_weights(context_scores)
end
```

**Step 2: ML-Based Context Detection (8-10 hours)**
```python
# Zero-shot classification with facebook/bart-large-mnli
def detect_context_ml(text):
    """
    More accurate context detection using ML.
    Classifies into: financial, political, social, mixed
    """
    classifier = pipeline("zero-shot-classification",
                         model="facebook/bart-large-mnli")

    candidate_labels = ["financial news", "political content",
                       "social media", "general news"]

    result = classifier(text, candidate_labels)
    return result
```

**Acceptance Criteria:**
- [ ] Keyword-based detection works for obvious cases
- [ ] ML detection improves accuracy by 20%+
- [ ] Context stored in classifications.meta
- [ ] Dynamic weighting improves consensus quality
- [ ] A/B testing shows improvement over static weights

**Estimated Effort:** 12-15 hours

---

### 8. Model Performance Dashboard (8-10 hours) 🟢

**Goal:** Real-time monitoring and analytics for model performance

**Features:**
- **Model Health:** Real-time latency, error rates, confidence trends
- **Agreement Analysis:** Which models agree most often?
- **Confidence Calibration:** Are confidence scores accurate?
- **Sentiment Distribution:** Track changes over time
- **Disagreement Patterns:** Common points of contention

**Implementation:**
```elixir
defmodule VolfefeMachine.Intelligence.Dashboard do
  @doc """
  Generate dashboard data for Phoenix LiveView.
  """
  def get_dashboard_data()

  @doc """
  Time-series data for model metrics.
  """
  def get_metrics_timeline(model_id, days \\ 30)

  @doc """
  Identify trending disagreement patterns.
  """
  def get_disagreement_trends()
end
```

**Acceptance Criteria:**
- [ ] Real-time metrics updated every minute
- [ ] Historical data retained for 90 days
- [ ] Configurable alerts for anomalies
- [ ] Export capabilities for reports

**Estimated Effort:** 8-10 hours

---

## PRIORITY 4: Future Research (30-40 hours)

### 9. ML Ensemble Meta-Classifier (20-25 hours) 🔵

**Goal:** Train a meta-classifier to learn optimal consensus from data

**Approach:**
```python
# Train on historical model outputs + human labels
# Features: model confidences, agreement patterns, text features
# Target: true sentiment (from manual review)

from sklearn.ensemble import RandomForestClassifier

def train_meta_classifier(training_data):
    """
    Learn to predict true sentiment from model outputs.
    Better than fixed weights or weighted voting.
    """
    features = [
        model1_confidence,
        model2_confidence,
        model3_confidence,
        agreement_rate,
        text_length,
        has_caps,
        has_exclamation
    ]

    clf = RandomForestClassifier()
    clf.fit(features, true_labels)
    return clf
```

**Estimated Effort:** 20-25 hours

---

### 10. A/B Testing Framework (10-12 hours) 🔵

**Goal:** Compare consensus algorithms scientifically

**Features:**
- Run different consensus versions in parallel
- Track accuracy, agreement, confidence calibration
- Statistical significance testing
- Automated rollback if new version underperforms

**Estimated Effort:** 10-12 hours

---

## Database Schema Enhancements (Phase 3)

### classifications table additions
```sql
-- Context and entity tracking
ALTER TABLE classifications ADD COLUMN IF NOT EXISTS
  context_type VARCHAR(50),           -- financial/political/social/mixed
  context_confidence FLOAT,           -- ML confidence in context
  primary_target VARCHAR(255),        -- Main entity mentioned
  all_targets TEXT[],                 -- All entities detected
  target_industries TEXT[],           -- Affected industries
  affected_tickers TEXT[];            -- Stock symbols mentioned

-- Quality and review tracking
ALTER TABLE classifications ADD COLUMN IF NOT EXISTS
  disagreement_flag BOOLEAN DEFAULT FALSE,  -- Models significantly disagree
  review_flag BOOLEAN DEFAULT FALSE,        -- Needs human review
  review_reason TEXT,                       -- Why flagged
  reviewed_at TIMESTAMP,                    -- Manual review timestamp
  reviewed_by VARCHAR(255),                 -- Reviewer identifier
  ground_truth_sentiment VARCHAR(50);       -- Human-verified sentiment

-- Consensus versioning
ALTER TABLE classifications ADD COLUMN IF NOT EXISTS
  consensus_version VARCHAR(20),      -- v1.0, v2.0, etc.
  consensus_method VARCHAR(50);       -- weighted_vote, ml_ensemble, etc.

CREATE INDEX IF NOT EXISTS idx_classifications_disagreement
  ON classifications(disagreement_flag) WHERE disagreement_flag = TRUE;

CREATE INDEX IF NOT EXISTS idx_classifications_review
  ON classifications(review_flag) WHERE review_flag = TRUE;
```

### model_classifications table additions
```sql
-- Execution tracking
ALTER TABLE model_classifications ADD COLUMN IF NOT EXISTS
  execution_order INTEGER,            -- Sequence in batch
  execution_mode VARCHAR(20),         -- parallel/sequential
  cache_hit BOOLEAN DEFAULT FALSE,    -- Was result cached?
  cached_from_id BIGINT REFERENCES model_classifications(id);

-- Context relevance
ALTER TABLE model_classifications ADD COLUMN IF NOT EXISTS
  context_relevance FLOAT,            -- How relevant is this model?
  weight_override FLOAT;              -- Dynamic weight adjustment

CREATE INDEX IF NOT EXISTS idx_model_classifications_cache
  ON model_classifications(cache_hit, cached_from_id);
```

---

## Success Metrics

### Phase 3 Completion Criteria

**Query API (CRITICAL):**
- [ ] All query functions implemented and tested
- [ ] Zero raw SQL queries needed for common operations
- [ ] Response time < 100ms for single content queries
- [ ] Response time < 1s for aggregate queries

**Analytics & Monitoring:**
- [ ] Real-time dashboard operational
- [ ] Historical metrics tracked for 90 days
- [ ] Alerting configured for anomalies
- [ ] Monthly performance reports automated

**Performance:**
- [ ] Parallel execution reduces latency by 60%+
- [ ] Cache hit rate > 30% for production traffic
- [ ] 99th percentile latency < 2 seconds
- [ ] Memory usage < 2GB for model loading

**Quality Improvements:**
- [ ] Consensus v2.0 improves accuracy by 10%+
- [ ] Context detection correctly identifies type 85%+ of time
- [ ] Disagreement detection flags 90%+ of contentious cases
- [ ] Human review accuracy > 95%

---

## Implementation Roadmap

### Sprint 1 (Week 1): Critical Features
- Day 1-2: Query API implementation
- Day 3-4: Disagreement detection system
- Day 5: Model analytics functions

**Deliverable:** Full programmatic access to multi-model data

---

### Sprint 2 (Week 2): Performance
- Day 1-2: Parallel model execution
- Day 3-4: Enhanced consensus algorithm v2.0
- Day 5: Caching implementation

**Deliverable:** 60%+ latency reduction, improved consensus quality

---

### Sprint 3 (Week 3-4): Advanced Features
- Week 3: Context detection and smart routing
- Week 4: Performance dashboard and monitoring

**Deliverable:** Context-aware classification, real-time monitoring

---

### Sprint 4 (Week 5-6): Research & Optimization
- Week 5: ML ensemble meta-classifier
- Week 6: A/B testing framework

**Deliverable:** Data-driven consensus optimization

---

## Testing Requirements

### Unit Tests
- [ ] Query API: 15+ tests for all functions
- [ ] Disagreement detection: 10+ tests for edge cases
- [ ] Analytics: 12+ tests for metrics calculations
- [ ] Context detection: 20+ tests for all context types
- [ ] Consensus v2.0: 15+ tests for algorithm variants

### Integration Tests
- [ ] Parallel execution: End-to-end latency tests
- [ ] Caching: Cache hit/miss scenarios
- [ ] Dashboard: Data pipeline validation
- [ ] A/B testing: Statistical significance tests

### Performance Benchmarks
- [ ] Latency: Parallel vs sequential (target: 60% reduction)
- [ ] Memory: Model loading and caching (target: < 2GB)
- [ ] Throughput: Classifications per second (target: 10+)

---

## Documentation Requirements

- [ ] API documentation for all new query functions
- [ ] Context detection guide with examples
- [ ] Performance tuning guide
- [ ] Dashboard user guide
- [ ] A/B testing cookbook
- [ ] Migration guide for v2.0 consensus

---

## Risk Assessment

### Technical Risks

**Risk: Parallel execution increases memory usage**
- **Mitigation:** Load models once, share across processes
- **Fallback:** Sequential execution with batch processing

**Risk: Context detection adds latency**
- **Mitigation:** Cache context for similar content
- **Fallback:** Disable for low-latency requirements

**Risk: Consensus v2.0 performs worse than v1.0**
- **Mitigation:** A/B testing before full rollout
- **Fallback:** Keep v1.0 as default, v2.0 as opt-in

### Operational Risks

**Risk: Dashboard adds database load**
- **Mitigation:** Use read replicas for analytics
- **Fallback:** Pre-computed metrics with hourly updates

**Risk: Model updates break consensus**
- **Mitigation:** Version tracking in model_version field
- **Fallback:** Pin to specific model versions

---

## Dependencies

### Required Before Starting
- ✅ Phase 2.5 complete (Issues #20, #18 closed)
- ✅ All tests passing (77 unit + 8 integration)
- ✅ Production data migrated successfully

### External Dependencies
- Python 3.9+ with multiprocessing support
- PostgreSQL 13+ with JSONB support
- Phoenix LiveView for dashboard (optional)
- HuggingFace Transformers 4.30+

---

## Related Issues

- Closes remaining work from #16 (Multi-Model Architecture Vision)
- Builds on #20 (Multi-Model Architecture - COMPLETED)
- Uses schema from #18 (Multi-Classification Schema - COMPLETED)
- Enables future #13 (Phase 2.5 Audit - IN PROGRESS)

---

## Acceptance Criteria (Phase 3 Complete)

### Functionality
- [ ] All query API functions working
- [ ] Disagreement detection operational
- [ ] Model analytics accessible
- [ ] Parallel execution deployed
- [ ] Consensus v2.0 available
- [ ] Context detection functional
- [ ] Dashboard operational

### Performance
- [ ] Latency reduced by 60%+
- [ ] Cache hit rate > 30%
- [ ] Query response time < 100ms
- [ ] Dashboard loads < 2s

### Quality
- [ ] Test coverage > 90%
- [ ] All documentation complete
- [ ] Production monitoring active
- [ ] Zero critical bugs

### Impact
- [ ] Consensus accuracy improved by 10%+
- [ ] Human review reduced by 50%+
- [ ] Operational visibility increased
- [ ] Model optimization data-driven

---

## Estimated Total Effort

| Priority | Component | Hours |
|----------|-----------|-------|
| P1 | Query API | 2-3 |
| P1 | Disagreement Detection | 2-3 |
| P1 | Model Analytics | 3-4 |
| P2 | Parallel Execution | 4-5 |
| P2 | Enhanced Consensus | 4-5 |
| P2 | Caching | 2-3 |
| P3 | Context Detection | 12-15 |
| P3 | Performance Dashboard | 8-10 |
| P4 | ML Ensemble | 20-25 |
| P4 | A/B Testing | 10-12 |
| **Total** | **Complete Phase 3** | **68-85 hours** |

**Critical Path (P1):** 8-10 hours
**Full P1+P2:** 18-25 hours
**Complete P1+P2+P3:** 38-50 hours

---

## Success Criteria for Closing

This issue can be closed when:
1. ✅ All P1 (Critical) features implemented and tested
2. ✅ All P2 (Performance) features deployed to production
3. ✅ P3 (Advanced) features at minimum viable state
4. ✅ Documentation complete
5. ✅ Production metrics showing improvements
6. ✅ Zero blocking bugs
7. ✅ Team trained on new features

**Target Date:** 6-8 weeks from start

---

**Created:** 2025-10-27
**Created By:** Audit of Issues #16, #18, #20
**Phase:** 3 (Enhancement & Optimization)
**Status:** Ready to Start
