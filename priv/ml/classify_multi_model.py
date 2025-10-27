#!/usr/bin/env python3
"""
Multi-Model Sentiment Classification for Volfefe Machine.

Runs multiple sentiment analysis models on the same text and returns all results.
Philosophy: Run ALL models, capture ALL data, decide consensus later in Elixir.

Models:
  - DistilBERT (distilbert-base-uncased-finetuned-sst-2-english)
  - Twitter-RoBERTa (cardiffnlp/twitter-roberta-base-sentiment-latest)
  - FinBERT (yiyanghkust/finbert-tone)

Usage:
    echo "text to classify" | python3 classify_multi_model.py

Output format:
    {
      "results": [
        {
          "model_id": "distilbert",
          "model_version": "distilbert-base-uncased-finetuned-sst-2-english",
          "sentiment": "negative",
          "confidence": 0.9757,
          "meta": {...}
        },
        {
          "model_id": "twitter_roberta",
          ...
        },
        {
          "model_id": "finbert",
          ...
        }
      ],
      "text_info": {...},
      "total_latency_ms": 2300
    }
"""

import json
import sys
import time
import hashlib
import math
import platform
import traceback
from transformers import pipeline
import transformers
import torch

# Model configurations
# These match config/ml_models.exs
MODELS = {
    "distilbert": {
        "name": "distilbert-base-uncased-finetuned-sst-2-english",
        "label_map": {
            "POSITIVE": "positive",
            "NEGATIVE": "negative"
        },
        "has_neutral": False  # Binary classification
    },
    "twitter_roberta": {
        "name": "cardiffnlp/twitter-roberta-base-sentiment-latest",
        "label_map": {
            "positive": "positive",
            "neutral": "neutral",
            "negative": "negative",
            "LABEL_0": "negative",
            "LABEL_1": "neutral",
            "LABEL_2": "positive"
        },
        "has_neutral": True
    },
    "finbert": {
        "name": "yiyanghkust/finbert-tone",
        "label_map": {
            "LABEL_0": "neutral",
            "LABEL_1": "positive",
            "LABEL_2": "negative"
        },
        "has_neutral": True
    }
}

def load_models():
    """
    Load all sentiment analysis models.

    Returns:
        dict: Loaded pipeline for each model_id
    """
    models = {}
    device = 0 if torch.cuda.is_available() else -1

    print("Loading sentiment models...", file=sys.stderr)

    for model_id, config in MODELS.items():
        try:
            print(f"  Loading {model_id} ({config['name']})...", file=sys.stderr)
            models[model_id] = pipeline(
                "sentiment-analysis",
                model=config["name"],
                device=device
            )
        except Exception as e:  # noqa: BLE001 - intentional broad catch for model loading
            print(f"  Error loading {model_id}: {str(e)}", file=sys.stderr)
            traceback.print_exc(file=sys.stderr)
            # Continue loading other models even if one fails
            continue

    print(f"  Loaded {len(models)}/{len(MODELS)} models\n", file=sys.stderr)
    return models

def get_system_info():
    """Capture system and environment configuration."""
    return {
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

def classify_with_model(model_id, classifier, text, model_config):
    """
    Classify text using a specific model.

    Args:
        model_id: Model identifier ("distilbert", "twitter_roberta", "finbert")
        classifier: Loaded pipeline
        text: Text to classify
        model_config: Model configuration from MODELS

    Returns:
        dict: Classification result with comprehensive metadata
    """
    start_time = time.time()

    try:
        # Get all scores from model (top_k=None for all classes)
        all_results = classifier(text, top_k=None)

        # Calculate latency immediately after model call
        latency_ms = int((time.time() - start_time) * 1000)

        # Handle both list-of-lists and list-of-dicts formats
        if isinstance(all_results[0], list):
            results = all_results[0]  # Get inner list
        else:
            results = all_results  # Already a list of dicts

        # Find the highest scoring label
        top_result = max(results, key=lambda x: x['score'])

        # Map label to sentiment using model-specific label map
        label_map = model_config["label_map"]
        raw_label = top_result['label']
        sentiment = label_map.get(raw_label, raw_label).lower()
        confidence = top_result['score']

        # Build raw scores dict
        raw_scores = {}
        for result in results:
            label = label_map.get(result['label'], result['label']).lower()
            raw_scores[label] = round(result['score'], 4)

        # Capture ALL metadata
        return {
            "model_id": model_id,
            "model_version": model_config["name"],
            "sentiment": sentiment,
            "confidence": round(confidence, 4),
            "meta": {
                "raw_scores": raw_scores,
                "processing": {
                    "latency_ms": latency_ms,
                    "timestamp": time.strftime("%Y-%m-%dT%H:%M:%SZ", time.gmtime())
                },
                "model_config": {
                    "model_name": model_config["name"],
                    "has_neutral_class": model_config["has_neutral"]
                },
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

    except Exception as e:  # noqa: BLE001 - intentional broad catch for model classification
        # Return error for this specific model
        print(f"Error classifying with {model_id}: {str(e)}", file=sys.stderr)
        traceback.print_exc(file=sys.stderr)
        latency_ms = int((time.time() - start_time) * 1000)
        return {
            "model_id": model_id,
            "model_version": model_config["name"],
            "error": str(e),
            "meta": {
                "processing": {
                    "latency_ms": latency_ms,
                    "timestamp": time.strftime("%Y-%m-%dT%H:%M:%SZ", time.gmtime())
                }
            }
        }

def classify_all_models(models, text):
    """
    Run all models on the same text.

    Args:
        models: Dict of loaded model pipelines
        text: Text to classify

    Returns:
        dict: Results from all models with metadata
    """
    total_start_time = time.time()

    results = []

    for model_id, classifier in models.items():
        config = MODELS[model_id]
        result = classify_with_model(model_id, classifier, text, config)
        results.append(result)

    total_latency_ms = int((time.time() - total_start_time) * 1000)

    return {
        "results": results,
        "text_info": get_text_info(text),
        "system_info": get_system_info(),
        "total_latency_ms": total_latency_ms,
        "models_used": list(models.keys()),
        "total_models": len(results),
        "successful_models": len([r for r in results if "error" not in r]),
        "failed_models": len([r for r in results if "error" in r])
    }

def main():
    """Main entry point - read from stdin, classify with all models, write to stdout."""
    try:
        # Load all models
        models = load_models()

        if not models:
            result = {
                "error": "no_models_loaded",
                "message": "Failed to load any sentiment analysis models"
            }
            print(json.dumps(result))
            sys.exit(1)

        # Read text from stdin
        text = sys.stdin.read().strip()

        if not text:
            result = {
                "error": "no_text_provided",
                "message": "No text provided for classification"
            }
        else:
            # Classify with all models
            result = classify_all_models(models, text)

        # Output JSON to stdout
        print(json.dumps(result, indent=2))

    except Exception as e:  # noqa: BLE001 - intentional broad catch for main execution
        # Return error as JSON
        print(f"Fatal error in classification pipeline: {str(e)}", file=sys.stderr)
        traceback.print_exc(file=sys.stderr)
        error_result = {
            "error": "classification_failed",
            "message": str(e)
        }
        print(json.dumps(error_result))
        sys.exit(1)

if __name__ == "__main__":
    main()
