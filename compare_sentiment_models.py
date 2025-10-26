#!/usr/bin/env python3
"""
Compare multiple sentiment analysis models on Trump Truth Social posts.

Tests:
1. FinBERT (yiyanghkust/finbert-tone) - Current model, financial news trained
2. Twitter-RoBERTa (cardiffnlp/twitter-roberta-base-sentiment) - Twitter trained
3. DistilBERT SST-2 (distilbert-base-uncased-finetuned-sst-2-english) - General sentiment

Goal: Find model that better captures political sentiment vs financial sentiment.
"""

import json
import psycopg2
from transformers import pipeline
import time

# Database connection
conn = psycopg2.connect(
    host="localhost",
    database="volfefe_machine_dev",
    user="postgres",
    password="postgres"
)

# Load models
print("=" * 80)
print("Loading Sentiment Models...")
print("=" * 80)

print("\n1/3 Loading FinBERT (financial news)...")
finbert = pipeline(
    "sentiment-analysis",
    model="yiyanghkust/finbert-tone",
    device=-1
)

print("2/3 Loading Twitter-RoBERTa (social media)...")
twitter_roberta = pipeline(
    "sentiment-analysis",
    model="cardiffnlp/twitter-roberta-base-sentiment-latest",
    device=-1
)

print("3/3 Loading DistilBERT SST-2 (general sentiment)...")
distilbert = pipeline(
    "sentiment-analysis",
    model="distilbert-base-uncased-finetuned-sst-2-english",
    device=-1
)

print("\n✅ All models loaded!\n")

# Fetch sample posts from database
cursor = conn.cursor()
cursor.execute("""
    SELECT c.id, c.text, cl.sentiment as current_sentiment, cl.confidence as current_confidence
    FROM contents c
    LEFT JOIN classifications cl ON cl.content_id = c.id
    WHERE c.text IS NOT NULL AND c.text != ''
    ORDER BY c.id
    LIMIT 20
""")

posts = cursor.fetchall()

print("=" * 80)
print(f"Testing {len(posts)} Trump Truth Social Posts")
print("=" * 80)

# Label mapping for different models
FINBERT_LABEL_MAP = {
    "LABEL_0": "neutral",
    "LABEL_1": "positive",
    "LABEL_2": "negative",
    "Positive": "positive",
    "Negative": "negative",
    "Neutral": "neutral"
}

TWITTER_LABEL_MAP = {
    "LABEL_0": "negative",
    "LABEL_1": "neutral",
    "LABEL_2": "positive"
}

DISTILBERT_LABEL_MAP = {
    "LABEL_0": "negative",
    "LABEL_1": "positive",
    "POSITIVE": "positive",
    "NEGATIVE": "negative"
}

results = []

for idx, (content_id, text, current_sentiment, current_confidence) in enumerate(posts, 1):
    print(f"\n[{idx}/{len(posts)}] Content ID: {content_id}")
    print(f"Text: {text[:100]}..." if len(text) > 100 else f"Text: {text}")

    # FinBERT
    start = time.time()
    fb_result = finbert(text, top_k=None)[0]
    fb_time = int((time.time() - start) * 1000)

    # Handle different output formats
    if isinstance(fb_result, list):
        fb_top = max(fb_result, key=lambda x: x['score'])
    else:
        fb_top = fb_result

    fb_sentiment = FINBERT_LABEL_MAP.get(fb_top['label'], fb_top['label'].lower())
    fb_confidence = fb_top['score']

    # Twitter-RoBERTa
    start = time.time()
    tw_result = twitter_roberta(text, top_k=None)[0]
    tw_time = int((time.time() - start) * 1000)

    if isinstance(tw_result, list):
        tw_top = max(tw_result, key=lambda x: x['score'])
    else:
        tw_top = tw_result

    tw_sentiment = TWITTER_LABEL_MAP.get(tw_top['label'], tw_top['label'].lower())
    tw_confidence = tw_top['score']

    # DistilBERT
    start = time.time()
    db_result = distilbert(text, top_k=None)[0]
    db_time = int((time.time() - start) * 1000)

    if isinstance(db_result, list):
        db_top = max(db_result, key=lambda x: x['score'])
    else:
        db_top = db_result

    db_sentiment = DISTILBERT_LABEL_MAP.get(db_top['label'], db_top['label'].lower())
    db_confidence = db_top['score']

    # Compare
    print(f"\n  Current DB:      {current_sentiment or 'N/A':8s} ({current_confidence or 0:.4f})")
    print(f"  FinBERT:         {fb_sentiment:8s} ({fb_confidence:.4f}) - {fb_time}ms")
    print(f"  Twitter-RoBERTa: {tw_sentiment:8s} ({tw_confidence:.4f}) - {tw_time}ms")
    print(f"  DistilBERT:      {db_sentiment:8s} ({db_confidence:.4f}) - {db_time}ms")

    # Flag disagreements
    sentiments = {fb_sentiment, tw_sentiment, db_sentiment}
    if len(sentiments) > 1:
        print(f"  ⚠️  DISAGREEMENT: Models disagree on sentiment!")

    results.append({
        "content_id": content_id,
        "text": text,
        "current_db": {
            "sentiment": current_sentiment,
            "confidence": float(current_confidence) if current_confidence else None
        },
        "finbert": {
            "sentiment": fb_sentiment,
            "confidence": round(fb_confidence, 4),
            "latency_ms": fb_time
        },
        "twitter_roberta": {
            "sentiment": tw_sentiment,
            "confidence": round(tw_confidence, 4),
            "latency_ms": tw_time
        },
        "distilbert": {
            "sentiment": db_sentiment,
            "confidence": round(db_confidence, 4),
            "latency_ms": db_time
        }
    })

# Summary statistics
print("\n" + "=" * 80)
print("SUMMARY STATISTICS")
print("=" * 80)

# Count sentiments by model
def count_sentiments(results, model_key):
    counts = {"positive": 0, "negative": 0, "neutral": 0}
    for r in results:
        sentiment = r[model_key]["sentiment"]
        counts[sentiment] = counts.get(sentiment, 0) + 1
    return counts

fb_counts = count_sentiments(results, "finbert")
tw_counts = count_sentiments(results, "twitter_roberta")
db_counts = count_sentiments(results, "distilbert")

total = len(results)

print(f"\nFinBERT (Financial News):")
print(f"  Positive: {fb_counts['positive']:2d} ({fb_counts['positive']/total*100:5.1f}%)")
print(f"  Neutral:  {fb_counts['neutral']:2d} ({fb_counts['neutral']/total*100:5.1f}%)")
print(f"  Negative: {fb_counts['negative']:2d} ({fb_counts['negative']/total*100:5.1f}%)")

print(f"\nTwitter-RoBERTa (Social Media):")
print(f"  Positive: {tw_counts['positive']:2d} ({tw_counts['positive']/total*100:5.1f}%)")
print(f"  Neutral:  {tw_counts['neutral']:2d} ({tw_counts['neutral']/total*100:5.1f}%)")
print(f"  Negative: {tw_counts['negative']:2d} ({tw_counts['negative']/total*100:5.1f}%)")

print(f"\nDistilBERT (General Sentiment):")
print(f"  Positive: {db_counts['positive']:2d} ({db_counts['positive']/total*100:5.1f}%)")
print(f"  Neutral:  {db_counts['neutral']:2d} ({db_counts['neutral']/total*100:5.1f}%)")
print(f"  Negative: {db_counts['negative']:2d} ({db_counts['negative']/total*100:5.1f}%)")

# Agreement analysis
agreements = 0
for r in results:
    fb_sent = r["finbert"]["sentiment"]
    tw_sent = r["twitter_roberta"]["sentiment"]
    db_sent = r["distilbert"]["sentiment"]

    if fb_sent == tw_sent == db_sent:
        agreements += 1

print(f"\n🤝 Model Agreement:")
print(f"  All 3 models agree: {agreements}/{total} ({agreements/total*100:.1f}%)")
print(f"  Models disagree:    {total-agreements}/{total} ({(total-agreements)/total*100:.1f}%)")

# Save results
with open("model_comparison_results.json", "w") as f:
    json.dump({
        "summary": {
            "total_posts": total,
            "finbert": fb_counts,
            "twitter_roberta": tw_counts,
            "distilbert": db_counts,
            "agreement_rate": round(agreements / total, 4)
        },
        "details": results
    }, f, indent=2)

print(f"\n✅ Results saved to model_comparison_results.json")

conn.close()
