"""
Test standard FinBERT model via Python transformers library
This is the fallback from GGUF approach
"""
from transformers import pipeline
import json

# Load FinBERT model
print("Loading FinBERT model...")
classifier = pipeline(
    "sentiment-analysis",
    model="yiyanghkust/finbert-tone",
    device=-1  # CPU, use 0 for GPU
)
print("✅ Model loaded!\n")

# Test texts
test_texts = [
    "Stock market hitting record highs! Economic boom ahead!",
    "Massive tariffs will devastate the steel industry",
    "The Federal Reserve announced interest rate decision",
    "THE STOCK MARKET IS STRONGER THAN EVER BEFORE BECAUSE OF TARIFFS!",
    "Canada was caught, red handed, putting up a fraudulent advertisement on Ronald Reagan's Speech on Tariffs"
]

print("=" * 80)
print("Testing FinBERT Classification")
print("=" * 80)

results = []
for text in test_texts:
    result = classifier(text)[0]

    # Map LABEL_X to readable sentiment
    label_map = {
        "LABEL_0": "neutral",
        "LABEL_1": "positive",
        "LABEL_2": "negative"
    }

    sentiment = label_map.get(result["label"], result["label"])
    confidence = result["score"]

    print(f"\nText: {text[:80]}...")
    print(f"Sentiment: {sentiment}")
    print(f"Confidence: {confidence:.4f}")
    print("-" * 80)

    results.append({
        "text": text,
        "sentiment": sentiment,
        "confidence": confidence,
        "label": result["label"]
    })

# Save results
with open("finbert_test_results.json", "w") as f:
    json.dump(results, indent=2, fp=f)

print(f"\n✅ Results saved to finbert_test_results.json")
