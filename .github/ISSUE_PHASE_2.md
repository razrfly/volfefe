# Phase 2: FinBERT Sentiment Classification Setup

## Overview

This phase establishes ML-based sentiment classification for the Volfefe Machine using **FinBERT** (`yiyanghkust/finbert-tone`), a BERT model pre-trained on 4.9B tokens of financial communications and fine-tuned on 10,000 manually annotated analyst reports. FinBERT is specifically designed for financial text sentiment analysis, making it ideal for classifying Trump Truth Social posts for market impact assessment.

**Why FinBERT?**
- **Domain-Specific**: Pre-trained on financial text (earnings calls, analyst reports, financial news)
- **Proven Performance**: Superior accuracy on financial sentiment tasks vs. general-purpose models
- **Three-Class Output**: Neutral, Positive, Negative sentiment with confidence scores
- **Hugging Face Integration**: Simple pipeline API for inference
- **Research-Backed**: Published in *Contemporary Accounting Research* (2022)

**Current Status**: 100 Trump Truth Social posts successfully imported into PostgreSQL database, ready for classification.

---

## Strategy: Output-First, Schema-Later

**Approach**:
1. Set up FinBERT and run it on our 100 posts
2. Examine actual outputs to see what information it provides
3. Decide what to save based on real results
4. For now, can store everything in `meta` JSONB field if needed
5. Iterate on schema design in Phase 2B after seeing results

---

## Setup Instructions

### Prerequisites

- **Python 3.9+** (check with `python3 --version`)
- **4GB+ RAM** available for model inference
- **~1GB disk space** for model weights download
- **Active internet connection** for first-time model download

### Step 1: Create Python Service Directory

```bash
cd /Users/holdenthomas/Code/paid-projects-2025/volfefe_machine
mkdir ml_service
cd ml_service
```

### Step 2: Set Up Python Virtual Environment

```bash
# Create virtual environment
python3 -m venv venv

# Activate it
source venv/bin/activate

# You should see (venv) in your terminal prompt
```

### Step 3: Install Dependencies

Create `requirements.txt`:
```
torch>=2.0.0
transformers>=4.30.0
fastapi>=0.100.0
uvicorn[standard]>=0.23.0
pydantic>=2.0.0
```

Install:
```bash
pip install -r requirements.txt
```

**Note**: First install will take 5-10 minutes and download ~2GB of dependencies.

### Step 4: Create Basic Classifier Service

Create `classifier.py` with:
- FastAPI app that loads FinBERT model on startup
- `/classify` endpoint that accepts text and returns sentiment
- `/classify-batch` endpoint for processing multiple texts efficiently
- Model returns: sentiment label, confidence score, all label scores

**Key implementation points**:
- Use `transformers.pipeline("sentiment-analysis", model="yiyanghkust/finbert-tone")`
- Model returns `LABEL_0` (neutral), `LABEL_1` (positive), `LABEL_2` (negative)
- Request `top_k=None` to get scores for all three labels
- Include latency tracking to measure performance

### Step 5: Test the Service

Start service:
```bash
uvicorn classifier:app --reload --port 8001
```

Test with curl:
```bash
# Test positive sentiment
curl -X POST "http://localhost:8001/classify" \
  -H "Content-Type: application/json" \
  -d '{"text": "Stock market hitting record highs! Economic boom ahead!"}'

# Test negative sentiment
curl -X POST "http://localhost:8001/classify" \
  -H "Content-Type: application/json" \
  -d '{"text": "Massive tariffs will devastate the steel industry"}'

# Test neutral sentiment
curl -X POST "http://localhost:8001/classify" \
  -H "Content-Type: application/json" \
  -d '{"text": "The Federal Reserve announced interest rate decision"}'
```

**Expected output format**:
```json
{
  "sentiment": "negative",
  "confidence": 0.8543,
  "all_scores": {
    "positive": 0.0234,
    "negative": 0.8543,
    "neutral": 0.1223
  },
  "latency_ms": 245
}
```

### Step 6: Test with Real Posts from Database

Create a test script `test_with_db_posts.exs`:
```elixir
# Fetch 5 sample posts from database
alias VolfefeMachine.Content

posts = Content.list_contents() |> Enum.take(5)

Enum.each(posts, fn post ->
  IO.puts("\n" <> String.duplicate("=", 80))
  IO.puts("Post ID: #{post.id}")
  IO.puts("Date: #{post.published_at}")
  IO.puts("Text: #{String.slice(post.text || "", 0..200)}...")

  # Make HTTP request to classifier
  response = Req.post!("http://localhost:8001/classify", json: %{text: post.text})

  IO.puts("\nFinBERT Result:")
  IO.inspect(response.body, pretty: true)
end)
```

Run:
```bash
mix run test_with_db_posts.exs
```

### Step 7: Analyze Outputs

Examine the results from Step 6 to understand:

1. **Sentiment Distribution**: How many positive/negative/neutral?
2. **Confidence Levels**: Are scores generally high (>0.7) or uncertain (<0.5)?
3. **Score Patterns**: Do posts have mixed signals (e.g., 40% pos, 35% neg, 25% neutral)?
4. **Edge Cases**: Any posts that fail or return unexpected results?
5. **Performance**: What's the average latency per post?

**Key Questions to Answer**:
- Do we need all three scores or just the predicted sentiment?
- Should we filter out low-confidence classifications?
- Do we see any patterns in tariff-related posts vs others?
- Is the model appropriate for Trump's writing style?

### Step 8: Batch Test All 100 Posts

Create `classify_all_posts.exs`:
```elixir
alias VolfefeMachine.Content

posts = Content.list_contents()

# Prepare batch request
texts = Enum.map(posts, & &1.text)

IO.puts("🚀 Classifying #{length(posts)} posts...")

response = Req.post!("http://localhost:8001/classify-batch",
  json: %{texts: texts},
  receive_timeout: 60_000  # 60 second timeout
)

results = response.body["results"]

IO.puts("✅ Classified #{length(results)} posts")
IO.puts("⏱️  Total time: #{response.body["total_latency_ms"]}ms")
IO.puts("📊 Avg per post: #{div(response.body["total_latency_ms"], length(results))}ms")

# Analyze distribution
sentiment_counts =
  results
  |> Enum.frequencies_by(& &1["sentiment"])

IO.puts("\n📈 Sentiment Distribution:")
IO.inspect(sentiment_counts, pretty: true)

# Show high-confidence examples
IO.puts("\n🎯 High Confidence Examples:")

results
|> Enum.zip(posts)
|> Enum.filter(fn {result, _post} -> result["confidence"] > 0.85 end)
|> Enum.take(5)
|> Enum.each(fn {result, post} ->
  IO.puts("\n#{result["sentiment"]} (#{result["confidence"]})")
  IO.puts("  #{String.slice(post.text || "", 0..100)}...")
end)

# Save full results to JSON for analysis
File.write!("classification_results.json", Jason.encode!(results, pretty: true))
IO.puts("\n💾 Saved results to classification_results.json")
```

Run:
```bash
mix run classify_all_posts.exs
```

---

## What to Look For in Results

### 1. Sentiment Accuracy
- Do tariff posts show as negative/bearish?
- Do economic success posts show as positive/bullish?
- Are endorsement posts classified appropriately?

### 2. Confidence Patterns
- What % of posts have >0.8 confidence?
- Are there posts with very uncertain classifications (all scores ~0.33)?
- Do longer posts have different confidence than short ones?

### 3. Data to Potentially Store
Based on what you observe, decide which fields to persist:

**Minimal** (just predictions):
- `sentiment` (string)
- `confidence` (float)

**Standard** (include alternatives):
- `sentiment` (string)
- `confidence` (float)
- `all_scores` (map with all three scores)

**Detailed** (for analysis):
- All of above plus:
- `latency_ms` (performance tracking)
- `model_version` (for future model upgrades)
- `classified_at` (timestamp)

### 4. Model Appropriateness
- Is FinBERT good at understanding Trump's communication style?
- Does it handle ALL CAPS, excessive punctuation, emojis?
- Are there systematic misclassifications?

---

## Decision Points After Testing

### Schema Design Options

**Option A: Separate Table** (recommended if classifications are valuable)
```sql
CREATE TABLE classifications (
  id SERIAL PRIMARY KEY,
  content_id INTEGER REFERENCES contents(id),
  sentiment TEXT,
  confidence FLOAT,
  all_scores JSONB,
  -- add other fields as needed
  created_at TIMESTAMP
);
```

**Option B: JSONB in contents.meta** (quick iteration)
```elixir
Content.update_content(content_id, %{
  meta: Map.put(content.meta, "classification", %{
    "sentiment" => "negative",
    "confidence" => 0.87,
    "all_scores" => %{"positive" => 0.02, "negative" => 0.87, "neutral" => 0.11}
  })
})
```

**Option C: Hybrid** (classification table + rich meta)
- Core predictions in table for querying
- Detailed scores/metadata in JSONB for flexibility

### Integration Approach

After validating the model works well, decide:

1. **Keep HTTP Service** (recommended)
   - Easy to scale independently
   - Simple error handling
   - Can upgrade model without touching Elixir

2. **Elixir Port**
   - Lower latency
   - More complex to manage

3. **Background Jobs**
   - Use Oban to classify posts asynchronously
   - Queue new posts for classification
   - Retry on failures

---

## Success Criteria

- [ ] Python environment set up with all dependencies
- [ ] FinBERT model successfully loads (first run downloads ~440MB)
- [ ] Service responds to `/classify` endpoint correctly
- [ ] Batch endpoint successfully processes 100 posts
- [ ] Results saved to JSON for analysis
- [ ] Sentiment distribution looks reasonable (not all one class)
- [ ] Average latency <500ms per post on Mac
- [ ] Decision made on which fields to persist in database
- [ ] Observed if model handles Trump's writing style appropriately

---

## Next Steps After This Phase

**Phase 2B: Integration & Persistence**
- Create Elixir HTTP client module
- Design final database schema based on observed results
- Run migration
- Create classification context module
- Classify all 100 posts and persist results

**Phase 2C: Enhancements** (optional)
- Named entity recognition for companies/sectors
- Market relevance scoring
- Keyword extraction for tariff-specific terms

---

## Estimated Time

**Setup & Testing**: 2-3 hours
- Environment setup: 30 min
- Service creation: 30 min
- Testing with sample posts: 30 min
- Batch processing all 100: 30 min
- Analysis and decision-making: 1 hour

---

## Troubleshooting

**Issue**: `ModuleNotFoundError: No module named 'torch'`
```bash
# Solution: Ensure virtual environment is activated
source venv/bin/activate
pip install -r requirements.txt
```

**Issue**: Model download is slow/failing
```bash
# Solution: Check internet connection, may take 5-10 minutes
# Model downloads to ~/.cache/huggingface/
```

**Issue**: `Address already in use` on port 8001
```bash
# Solution: Use different port
uvicorn classifier:app --reload --port 8002
```

**Issue**: High memory usage
```bash
# Expected: FinBERT uses ~2-3GB RAM when loaded
# Solution: Close other applications or use batch processing
```

---

## References

- [FinBERT Paper](https://arxiv.org/abs/2006.08097)
- [Model Card](https://huggingface.co/yiyanghkust/finbert-tone)
- [Transformers Documentation](https://huggingface.co/docs/transformers)
- [FastAPI Tutorial](https://fastapi.tiangolo.com/tutorial/)

---

**Ready to start? Follow the setup instructions above and report back with the classification results!**
