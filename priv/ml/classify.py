#!/usr/bin/env python3
"""
FinBERT classification service for Volfefe Machine.

Accepts text via stdin, returns JSON classification result via stdout.
Designed to be called from Elixir via Port.

Usage:
    echo "text to classify" | python3 classify.py

Output format:
    {
      "sentiment": "positive",
      "confidence": 0.95,
      "model_version": "finbert-tone-v1.0",
      "meta": {
        "raw_scores": {
          "positive": 0.95,
          "negative": 0.02,
          "neutral": 0.03
        }
      }
    }
"""

import json
import sys
from transformers import pipeline

# Model version for tracking
MODEL_VERSION = "finbert-tone-v1.0"

# Label mapping from BERT output to human-readable sentiment
LABEL_MAP = {
    "LABEL_0": "neutral",
    "LABEL_1": "positive",
    "LABEL_2": "negative"
}

def load_model():
    """Load FinBERT model once at startup."""
    return pipeline(
        "sentiment-analysis",
        model="yiyanghkust/finbert-tone",
        device=-1  # CPU
    )

def classify_text(classifier, text):
    """
    Classify text using FinBERT.

    Args:
        classifier: Loaded FinBERT pipeline
        text: Text to classify

    Returns:
        dict: Classification result with sentiment, confidence, and metadata
    """
    # Get all three scores from model
    # The pipeline returns a list with one element (per input text)
    # That element contains a list of label/score dicts
    all_results = classifier(text, top_k=3)

    # Handle both list-of-lists and list-of-dicts formats
    if isinstance(all_results[0], list):
        results = all_results[0]  # Get inner list
    else:
        results = all_results  # Already a list of dicts

    # Find the highest scoring label
    top_result = max(results, key=lambda x: x['score'])

    # Map label to sentiment
    sentiment = LABEL_MAP.get(top_result['label'], top_result['label']).lower()
    confidence = top_result['score']

    # Build raw scores dict
    raw_scores = {}
    for result in results:
        label = LABEL_MAP.get(result['label'], result['label']).lower()
        raw_scores[label] = round(result['score'], 4)

    return {
        "sentiment": sentiment,
        "confidence": round(confidence, 4),
        "model_version": MODEL_VERSION,
        "meta": {
            "raw_scores": raw_scores
        }
    }

def main():
    """Main entry point - read from stdin, classify, write to stdout."""
    try:
        # Load model
        classifier = load_model()

        # Read text from stdin
        text = sys.stdin.read().strip()

        if not text:
            result = {
                "error": "no_text_provided",
                "message": "No text provided for classification"
            }
        else:
            # Classify
            result = classify_text(classifier, text)

        # Output JSON to stdout
        print(json.dumps(result))

    except Exception as e:
        # Return error as JSON
        error_result = {
            "error": "classification_failed",
            "message": str(e)
        }
        print(json.dumps(error_result))
        sys.exit(1)

if __name__ == "__main__":
    main()
