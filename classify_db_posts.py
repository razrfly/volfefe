"""
Classify all 100 posts from database using FinBERT
"""
from transformers import pipeline
import json
import sys

# Database connection setup
import os
import psycopg2
from psycopg2.extras import RealDictCursor
from dotenv import load_dotenv

# Load environment variables
load_dotenv()

# Load FinBERT model
print("🔄 Loading FinBERT model...")
classifier = pipeline(
    "sentiment-analysis",
    model="yiyanghkust/finbert-tone",
    device=-1  # CPU
)
print("✅ Model loaded!\n")

# Connect to database using environment variables
print("🔄 Connecting to database...")
conn = psycopg2.connect(
    host=os.getenv("PGHOST", "localhost"),
    database=os.getenv("PGDATABASE", "volfefe_machine_dev"),
    user=os.getenv("PGUSER", "postgres"),
    password=os.getenv("PGPASSWORD")
)
cur = conn.cursor(cursor_factory=RealDictCursor)

# Fetch all posts
print("📥 Fetching posts from database...")
cur.execute("""
    SELECT id, external_id, author, text, published_at, url
    FROM contents
    ORDER BY published_at DESC
""")
posts = cur.fetchall()
print(f"✅ Found {len(posts)} posts\n")

# Label mapping
label_map = {
    "LABEL_0": "neutral",
    "LABEL_1": "positive",
    "LABEL_2": "negative"
}

# Classify all posts
print("=" * 80)
print("Classifying posts...")
print("=" * 80)

results = []
sentiment_counts = {"positive": 0, "negative": 0, "neutral": 0}

for i, post in enumerate(posts, 1):
    if not post['text']:
        print(f"\n⚠️  Post {i}/{len(posts)}: Skipping (no text)")
        continue

    # Classify
    result = classifier(post['text'])[0]
    sentiment = label_map.get(result["label"], result["label"])
    confidence = result["score"]

    # Normalize to lowercase
    sentiment = sentiment.lower()

    # Track counts
    sentiment_counts[sentiment] += 1

    # Print progress
    if i % 10 == 0:
        print(f"✅ Processed {i}/{len(posts)} posts...")

    # Store result
    results.append({
        "id": post['id'],
        "external_id": post['external_id'],
        "text": post['text'][:200] + "..." if len(post['text']) > 200 else post['text'],
        "published_at": post['published_at'].isoformat() if post['published_at'] else None,
        "sentiment": sentiment,
        "confidence": round(confidence, 4),
        "url": post['url']
    })

print(f"\n✅ Classification complete!\n")

# Print summary statistics
print("=" * 80)
print("📊 SENTIMENT DISTRIBUTION")
print("=" * 80)
total = len(results)
for sentiment, count in sorted(sentiment_counts.items()):
    percentage = (count / total * 100) if total > 0 else 0
    print(f"{sentiment.upper():12} {count:3} ({percentage:5.1f}%)")
print(f"{'TOTAL':12} {total:3}")

# Show high-confidence examples
print("\n" + "=" * 80)
print("🎯 HIGH CONFIDENCE EXAMPLES (>0.9)")
print("=" * 80)

for sentiment_type in ["positive", "negative", "neutral"]:
    examples = [r for r in results if r["sentiment"] == sentiment_type and r["confidence"] > 0.9]
    if examples:
        print(f"\n{sentiment_type.upper()} ({len(examples)} examples):")
        for ex in examples[:2]:  # Show first 2
            print(f"  • {ex['text'][:100]}...")
            print(f"    Confidence: {ex['confidence']}")

# Show low-confidence examples
print("\n" + "=" * 80)
print("⚠️  LOW CONFIDENCE EXAMPLES (<0.7)")
print("=" * 80)

low_confidence = [r for r in results if r["confidence"] < 0.7]
print(f"Found {len(low_confidence)} posts with low confidence\n")
for ex in low_confidence[:5]:  # Show first 5
    print(f"{ex['sentiment'].upper()} ({ex['confidence']}):")
    print(f"  {ex['text'][:150]}...")
    print()

# Analyze tariff-related posts
print("=" * 80)
print("💰 TARIFF-RELATED POSTS")
print("=" * 80)

tariff_posts = [r for r in results if 'tariff' in r['text'].lower()]
print(f"Found {len(tariff_posts)} posts mentioning 'tariff'\n")

tariff_sentiments = {"positive": 0, "negative": 0, "neutral": 0}
for post in tariff_posts:
    tariff_sentiments[post['sentiment']] += 1

print("Tariff post sentiment distribution:")
for sentiment, count in sorted(tariff_sentiments.items()):
    print(f"  {sentiment.upper():12} {count:3}")

print("\nSample tariff posts:")
for post in tariff_posts[:3]:
    print(f"\n  {post['sentiment'].upper()} ({post['confidence']}):")
    print(f"  {post['text'][:150]}...")

# Save detailed results
output_file = "classification_results.json"
with open(output_file, "w") as f:
    json.dump({
        "total_posts": len(results),
        "sentiment_distribution": sentiment_counts,
        "high_confidence_count": len([r for r in results if r["confidence"] > 0.9]),
        "low_confidence_count": len(low_confidence),
        "tariff_posts_count": len(tariff_posts),
        "tariff_sentiments": tariff_sentiments,
        "results": results
    }, f, indent=2)

print(f"\n💾 Detailed results saved to {output_file}")

# Close database connection
cur.close()
conn.close()

print("\n✅ All done!")
