# Phase 2: FinBERT Sentiment Classification Setup (GGUF/Mac)

## Overview

Set up ML-based sentiment classification for the Volfefe Machine using a **quantized GGUF FinBERT model** optimized for Mac. This model runs via `llama.cpp` which is much simpler than Python/PyTorch setup.

**Model**: `DJMcNewgent/stock_sentiment_Finbert_label-Q8_0-GGUF`
- **Size**: 118MB (vs 440MB for standard FinBERT)
- **Format**: GGUF (quantized 8-bit)
- **Purpose**: Stock market sentiment analysis
- **Runs on**: llama.cpp (native Mac binary via brew)

**Current Status**: 100 Trump Truth Social posts imported into PostgreSQL, ready for classification.

---

## Strategy: Output-First, Schema-Later

1. Install llama.cpp on Mac via brew
2. Test the GGUF model with sample texts
3. Run it on our 100 posts to see actual outputs
4. Examine results and decide what to persist
5. Design schema based on real data
6. For now, can store everything in `meta` JSONB if needed

---

## Mac Setup Instructions

### Step 1: Install llama.cpp via Homebrew

```bash
brew install llama.cpp
```

This installs:
- `llama-cli` - Command-line interface for one-off inference
- `llama-server` - HTTP server for API access

Verify installation:
```bash
llama-cli --version
```

### Step 2: Test the Model with Sample Texts

**Test positive sentiment**:
```bash
llama-cli \
  --hf-repo DJMcNewgent/stock_sentiment_Finbert_label-Q8_0-GGUF \
  --hf-file stock_sentiment_finbert_label-q8_0.gguf \
  -p "Stock market hitting all-time highs! Economic boom ahead!"
```

**Test negative sentiment**:
```bash
llama-cli \
  --hf-repo DJMcNewgent/stock_sentiment_Finbert_label-Q8_0-GGUF \
  --hf-file stock_sentiment_finbert_label-q8_0.gguf \
  -p "Massive tariffs will devastate the steel industry"
```

**Test neutral sentiment**:
```bash
llama-cli \
  --hf-repo DJMcNewgent/stock_sentiment_Finbert_label-Q8_0-GGUF \
  --hf-file stock_sentiment_finbert_label-q8_0.gguf \
  -p "The Federal Reserve announced interest rate decision"
```

**Note**: First run downloads the 118MB model to `~/.cache/huggingface/`

### Step 3: Understand the Output Format

Observe what the model returns:
- Does it return sentiment labels (positive/negative/neutral)?
- Are there confidence scores?
- What's the exact output format?
- How fast is inference on your Mac?

**IMPORTANT**: GGUF models with llama.cpp are primarily designed for text generation. We need to verify:
1. If this BERT model works properly for classification
2. If outputs are structured or require parsing
3. If we need prompt engineering to get sentiment labels

### Step 4: Start llama-server for HTTP API Access

```bash
llama-server \
  --hf-repo DJMcNewgent/stock_sentiment_Finbert_label-Q8_0-GGUF \
  --hf-file stock_sentiment_finbert_label-q8_0.gguf \
  --port 8001 \
  -c 2048
```

Server will be available at `http://localhost:8001`

**Test with curl**:
```bash
curl http://localhost:8001/v1/completions \
  -H "Content-Type: application/json" \
  -d '{
    "prompt": "Big tariffs on steel coming soon!",
    "max_tokens": 100,
    "temperature": 0.1
  }'
```

### Step 5: Test with Database Posts

Create `test_gguf_classifier.exs`:

```elixir
# Test GGUF classifier with database posts
alias VolfefeMachine.Content

posts = Content.list_contents() |> Enum.take(5)

Enum.each(posts, fn post ->
  IO.puts("\n" <> String.duplicate("=", 80))
  IO.puts("Post ID: #{post.id}")
  IO.puts("Date: #{post.published_at}")
  text = String.slice(post.text || "", 0..200)
  IO.puts("Text: #{text}...")

  # Call llama-server API
  response = Req.post!("http://localhost:8001/v1/completions",
    json: %{
      prompt: post.text,
      max_tokens: 100,
      temperature: 0.1
    }
  )

  IO.puts("\nGGUF Model Result:")
  IO.inspect(response.body, pretty: true)
end)
```

Run:
```bash
# Start server in background
llama-server \
  --hf-repo DJMcNewgent/stock_sentiment_Finbert_label-Q8_0-GGUF \
  --hf-file stock_sentiment_finbert_label-q8_0.gguf \
  --port 8001 \
  -c 2048 &

# Wait for server to start
sleep 5

# Run test
mix run test_gguf_classifier.exs
```

---

## Fallback: Standard FinBERT via Python

**If GGUF model doesn't work well for classification**, fall back to standard approach:

### Python Alternative Setup

1. **Create Python environment**:
```bash
mkdir ml_service
cd ml_service
python3 -m venv venv
source venv/bin/activate
```

2. **Install dependencies**:
```bash
pip install torch transformers fastapi uvicorn
```

3. **Use standard FinBERT model**:
```python
from transformers import pipeline

classifier = pipeline(
    "sentiment-analysis",
    model="yiyanghkust/finbert-tone"
)

result = classifier("Big tariffs on steel!")
print(result)
# Output: [{'label': 'LABEL_2', 'score': 0.87}]
# LABEL_0=neutral, LABEL_1=positive, LABEL_2=negative
```

This approach is more proven but requires Python/PyTorch setup.

---

## What to Look For in Results

### 1. Model Suitability
- Does GGUF model properly classify sentiment?
- Are outputs structured and parseable?
- Do results make sense for financial context?

### 2. Output Format
Determine what the model returns:
- Direct sentiment labels? (positive/negative/neutral)
- Generated text that needs parsing?
- Confidence scores or probabilities?
- Raw logits that need interpretation?

### 3. Performance on Mac
- Inference latency per post?
- Memory usage?
- CPU utilization?
- Batch processing capability?

### 4. Accuracy on Trump Posts
- Does it understand Trump's communication style?
- Handles ALL CAPS appropriately?
- Recognizes tariff-related negativity?
- Handles political vs financial sentiment?

### 5. Data to Persist

Based on what you observe, decide which fields to save:

**Minimal** (just predictions):
- `sentiment` (string)
- `confidence` (float) - if available

**Standard** (include alternatives):
- `sentiment` (string)
- `confidence` (float)
- `all_scores` (map) - if model provides multiple class scores

**Detailed** (for analysis):
- All of above plus:
- `raw_output` (text) - unparsed model output
- `latency_ms` (performance tracking)
- `model_version` (for future model upgrades)
- `classified_at` (timestamp)

---

## Decision Points After Testing

### Model Selection

**Option A: Use GGUF Model** (if it works well)
- ✅ Simpler setup (just brew install)
- ✅ Smaller size (118MB)
- ✅ Native Mac performance
- ❓ Need to verify classification quality
- ❓ May require output parsing

**Option B: Use Standard Python FinBERT** (if GGUF problematic)
- ✅ Proven for classification tasks
- ✅ Clear API with confidence scores
- ✅ Well-documented
- ❌ Larger download (440MB)
- ❌ Requires Python environment

### Schema Design Options

**Option A: Separate Classifications Table**
```sql
CREATE TABLE classifications (
  id SERIAL PRIMARY KEY,
  content_id INTEGER REFERENCES contents(id),
  sentiment TEXT,
  confidence FLOAT,
  raw_output TEXT,
  model_version TEXT,
  created_at TIMESTAMP
);
```

**Option B: Store in contents.meta JSONB** (quick iteration)
```elixir
# Store in existing meta field
meta = %{
  "classification" => %{
    "sentiment" => "negative",
    "confidence" => 0.87,
    "model" => "GGUF-finbert",
    "classified_at" => DateTime.utc_now()
  }
}
```

**Option C: Hybrid Approach**
- Core fields (sentiment, confidence) in separate table for querying
- Detailed outputs in meta JSONB for flexibility

---

## Success Criteria

- [ ] llama.cpp successfully installed via brew
- [ ] GGUF model downloads and loads (118MB)
- [ ] Model responds to test prompts
- [ ] Output format is understood and parseable
- [ ] Tested on 5-10 sample posts from database
- [ ] Determined if model is suitable for our use case
- [ ] Documented actual output format
- [ ] Performance measured (latency, memory)
- [ ] Decision made: Use GGUF or fall back to Python
- [ ] Decision made: What fields to persist in database

---

## Troubleshooting

**Issue**: `brew install llama.cpp` fails
```bash
# Update brew first
brew update
brew upgrade

# Try again
brew install llama.cpp
```

**Issue**: Model download is slow
```bash
# Downloads to ~/.cache/huggingface/
# First run may take 2-3 minutes for 118MB
# Subsequent runs use cached model
```

**Issue**: llama-server won't start
```bash
# Check if port 8001 is already in use
lsof -i :8001

# Use different port
llama-server --port 8002 ...
```

**Issue**: Model outputs don't look like sentiment classifications
```bash
# This is expected - GGUF/llama.cpp is for generation, not classification
# Solution: Fall back to Python FinBERT approach
```

---

## Next Steps After This Phase

**Phase 2B: Integration & Persistence**
- Create Elixir HTTP client module (if using server)
- Design final database schema based on observed results
- Run migration
- Create classification context module
- Classify all 100 posts and persist results

**Phase 2C: Batch Processing** (if model works well)
- Process all 100 posts
- Analyze sentiment distribution
- Identify tariff-related posts
- Calculate statistics

---

## Estimated Time

**GGUF Approach**: 1-2 hours
- Install llama.cpp: 10 min
- Test model: 30 min
- Integrate with database posts: 30 min
- Analyze and decide: 30 min

**Python Fallback** (if needed): +2 hours
- Python environment setup: 30 min
- Install dependencies: 30 min
- Create service: 30 min
- Testing: 30 min

---

## References

- [GGUF Model Card](https://huggingface.co/DJMcNewgent/stock_sentiment_Finbert_label-Q8_0-GGUF)
- [llama.cpp GitHub](https://github.com/ggerganov/llama.cpp)
- [Original FinBERT Paper](https://arxiv.org/abs/2006.08097)
- [Standard FinBERT Model](https://huggingface.co/yiyanghkust/finbert-tone)

---

**Ready to start? Begin with Step 1 and report back what the GGUF model outputs!**
