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
        "raw_scores": {...},
        "processing": {...},
        "text_info": {...},
        "model_config": {...},
        "quality": {...}
      }
    }
"""

import json
import sys
import time
import hashlib
import math
import platform
from transformers import pipeline
import transformers
import torch

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

def get_system_info():
    """Capture system and model configuration - store everything raw."""
    return {
        "model_name": "yiyanghkust/finbert-tone",
        "device": "cuda:0" if torch.cuda.is_available() else "cpu",
        "transformers_version": transformers.__version__,
        "torch_version": torch.__version__,
        "python_version": platform.python_version(),
        "platform": platform.platform(),
        "processor": platform.processor()
    }

def get_text_info(text):
    """Capture text metadata - everything we can extract."""
    words = text.split()
    return {
        "char_count": len(text),
        "word_count": len(words),
        "line_count": text.count('\n') + 1,
        "input_hash": hashlib.sha256(text.encode()).hexdigest()[:16],
        "has_urls": 'http' in text.lower(),
        "has_hashtags": '#' in text,
        "has_mentions": '@' in text,
        "uppercase_ratio": sum(1 for c in text if c.isupper()) / len(text) if text else 0,
        "exclamation_count": text.count('!'),
        "question_count": text.count('?')
    }

def calculate_quality_metrics(raw_scores):
    """Calculate confidence quality metrics from raw scores."""
    scores = sorted(raw_scores.values(), reverse=True)

    # Score margin: difference between top 2 scores
    score_margin = scores[0] - scores[1] if len(scores) > 1 else 1.0

    # Shannon entropy: measure of uncertainty
    entropy = -sum(p * math.log2(p) if p > 0 else 0 for p in raw_scores.values())

    # Quality flags
    flags = []
    if scores[0] >= 0.95:
        flags.append("high_confidence")
    if scores[0] == 1.0:
        flags.append("perfect_score")
    if score_margin >= 0.8:
        flags.append("clear_winner")
    if score_margin < 0.3:
        flags.append("ambiguous")
    if entropy < 0.1:
        flags.append("low_uncertainty")
    if entropy > 1.0:
        flags.append("high_uncertainty")

    return {
        "score_margin": round(score_margin, 4),
        "entropy": round(entropy, 4),
        "flags": flags
    }

def classify_text(classifier, text):
    """
    Classify text using FinBERT.
    Captures EVERYTHING - latency, text info, model config, quality metrics.

    Args:
        classifier: Loaded FinBERT pipeline
        text: Text to classify

    Returns:
        dict: Classification result with comprehensive metadata
    """
    # Start timing
    start_time = time.time()

    # Get all three scores from model
    all_results = classifier(text, top_k=3)

    # Calculate latency immediately after model call
    latency_ms = int((time.time() - start_time) * 1000)

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

    # Capture ALL metadata
    return {
        "sentiment": sentiment,
        "confidence": round(confidence, 4),
        "model_version": MODEL_VERSION,
        "meta": {
            "raw_scores": raw_scores,
            "processing": {
                "latency_ms": latency_ms,
                "timestamp": time.strftime("%Y-%m-%dT%H:%M:%SZ", time.gmtime()),
                "attempt": 1  # Will be updated by Elixir on retry
            },
            "text_info": get_text_info(text),
            "model_config": get_system_info(),
            "quality": calculate_quality_metrics(raw_scores),
            "raw_model_output": [
                {
                    "label": r['label'],
                    "score": round(r['score'], 6)
                }
                for r in results
            ]
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
