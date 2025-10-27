import Config

# Sentiment Analysis Models Configuration
# This file configures which ML models are used for sentiment classification.
#
# Each model has:
# - id: Short identifier used in database
# - name: Full HuggingFace model path
# - type: Model category (sentiment, entity, etc.)
# - enabled: Whether to use this model
# - weight: Weight for consensus calculation (0.0-1.0, should sum to 1.0)
# - notes: Description of model strengths/weaknesses
#
# Philosophy: Run ALL enabled models, collect ALL results, calculate weighted consensus.
# No smart routing or context detection - just run everything and store it all.

config :volfefe_machine, :sentiment_models,
  models: [
    %{
      id: "distilbert",
      name: "distilbert-base-uncased-finetuned-sst-2-english",
      type: "sentiment",
      enabled: true,
      weight: 0.4,
      notes: """
      General sentiment analysis model trained on SST-2 dataset.
      Strengths: Fast (25-53ms), high accuracy on general text
      Weaknesses: Binary classification (no neutral class), may need threshold for neutral
      Best for: General political content
      """
    },
    %{
      id: "twitter_roberta",
      name: "cardiffnlp/twitter-roberta-base-sentiment-latest",
      type: "sentiment",
      enabled: true,
      weight: 0.4,
      notes: """
      RoBERTa model trained on Twitter data.
      Strengths: Good for informal text, caps, exclamations (90-144ms)
      Weaknesses: May be too general for targeted attacks
      Best for: Social media style content (Truth Social posts)
      """
    },
    %{
      id: "finbert",
      name: "yiyanghkust/finbert-tone",
      type: "sentiment",
      enabled: true,
      weight: 0.2,
      notes: """
      FinBERT model trained on financial news.
      Strengths: Good for economic/market language
      Weaknesses: POOR for political attacks, misses aggression (0% negative in testing)
      Best for: Comparison/baseline - kept to track disagreement
      Note: Lower weight (0.2) due to proven poor performance on political content
      """
    }
  ]

# Python ML Scripts
config :volfefe_machine, :ml_scripts,
  # Multi-model classifier (to be implemented in Part 2)
  multi_model_classifier: "priv/ml/classify_multi_model.py",
  # Legacy single-model classifier (current)
  single_model_classifier: "priv/ml/classify.py"

# Consensus Algorithm Configuration
config :volfefe_machine, :consensus,
  # Algorithm version for tracking
  version: "v1.0",
  # Method: weighted_vote, majority_vote, ml_ensemble
  method: :weighted_vote,
  # Minimum models required for consensus
  min_models: 2,
  # Confidence threshold for low-confidence flag
  low_confidence_threshold: 0.7,
  # Agreement threshold for disagreement flag
  low_agreement_threshold: 0.5
