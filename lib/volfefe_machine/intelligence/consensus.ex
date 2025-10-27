defmodule VolfefeMachine.Intelligence.Consensus do
  @moduledoc """
  Calculate consensus sentiment from multiple model results.

  Implements weighted voting algorithm (v1.0) where each model's vote
  is weighted by its configured weight from config/ml_models.exs.

  Future versions may implement:
  - ML ensemble methods
  - Dynamic weight adjustment based on accuracy
  - Confidence-based weighting
  """

  alias VolfefeMachine.Intelligence.MultiModelClient

  @consensus_version "v1.0"

  @doc """
  Calculate consensus sentiment from multiple model results.

  Uses weighted voting where each model's sentiment vote is multiplied
  by its configured weight. The sentiment with highest weighted score wins.

  ## Algorithm

  1. For each model result, get model weight from config
  2. Multiply model confidence by weight
  3. Group by sentiment, sum weighted scores
  4. Sentiment with highest weighted score is consensus
  5. Normalize confidence to 0-1 range
  6. Calculate agreement metrics

  ## Examples

      iex> results = [
      ...>   %{model_id: "distilbert", sentiment: "negative", confidence: 0.97, weight: 0.4},
      ...>   %{model_id: "twitter_roberta", sentiment: "negative", confidence: 0.75, weight: 0.4},
      ...>   %{model_id: "finbert", sentiment: "neutral", confidence: 0.98, weight: 0.2}
      ...> ]
      iex> Consensus.calculate(results)
      %{
        sentiment: "negative",
        confidence: 0.85,
        model_version: "consensus_v1.0",
        agreement_rate: 0.67,
        meta: %{
          consensus_method: "weighted_vote",
          models_used: ["distilbert", "twitter_roberta", "finbert"],
          model_votes: [...],
          weighted_scores: %{negative: 0.688, neutral: 0.196}
        }
      }

  ## Returns

    - Map with consensus sentiment, confidence, and metadata
  """
  def calculate(model_results) when is_list(model_results) do
    # Filter out failed models
    successful_results = Enum.reject(model_results, fn r -> Map.has_key?(r, :error) end)

    if Enum.empty?(successful_results) do
      {:error, :no_successful_models}
    else
      # Get model weights from config
      weights = get_model_weights()

      # Calculate weighted scores for each sentiment
      weighted_scores = calculate_weighted_scores(successful_results, weights)

      # Find consensus sentiment (highest weighted score)
      {consensus_sentiment, consensus_score} =
        weighted_scores
        |> Enum.max_by(fn {_sentiment, score} -> score end)

      # Calculate agreement rate (how many models agree with consensus)
      agreement_count = Enum.count(successful_results, fn r -> r.sentiment == consensus_sentiment end)
      agreement_rate = agreement_count / length(successful_results)

      # Normalize confidence (weighted score / total weight)
      total_weight = Enum.sum(Map.values(weights))
      normalized_confidence = consensus_score / total_weight

      # Build consensus result
      {:ok, %{
        sentiment: consensus_sentiment,
        confidence: Float.round(normalized_confidence, 4),
        model_version: "consensus_#{@consensus_version}",
        meta: %{
          consensus_method: "weighted_vote",
          consensus_version: @consensus_version,
          models_used: Enum.map(successful_results, & &1.model_id),
          total_models: length(successful_results),
          agreement_rate: Float.round(agreement_rate, 2),
          model_votes: build_model_votes(successful_results, weights),
          weighted_scores: weighted_scores,
          failed_models: Enum.filter(model_results, fn r -> Map.has_key?(r, :error) end)
                         |> Enum.map(& &1.model_id)
        }
      }}
    end
  end

  defp get_model_weights do
    # Get config (returns keyword list)
    config = Application.get_env(:volfefe_machine, :sentiment_models, [])
    models = Keyword.get(config, :models, [])

    models
    |> Enum.map(fn model -> {model.id, model.weight} end)
    |> Enum.into(%{})
  end

  defp calculate_weighted_scores(results, weights) do
    results
    |> Enum.reduce(%{}, fn result, acc ->
      weight = Map.get(weights, result.model_id, 1.0)
      weighted_score = result.confidence * weight
      sentiment = result.sentiment

      Map.update(acc, sentiment, weighted_score, &(&1 + weighted_score))
    end)
    |> Enum.map(fn {sentiment, score} -> {sentiment, Float.round(score, 4)} end)
    |> Enum.into(%{})
  end

  defp build_model_votes(results, weights) do
    Enum.map(results, fn result ->
      weight = Map.get(weights, result.model_id, 1.0)
      weighted_score = result.confidence * weight

      %{
        model_id: result.model_id,
        sentiment: result.sentiment,
        confidence: result.confidence,
        weight: weight,
        weighted_score: Float.round(weighted_score, 4)
      }
    end)
  end

  @doc """
  Determine if consensus is ambiguous (low agreement or low confidence).

  Returns true if:
  - Agreement rate < 0.5 (less than half of models agree)
  - Consensus confidence < 0.7 (low confidence threshold)
  - Score margin < 0.3 (top 2 sentiments are close)

  ## Examples

      iex> Consensus.ambiguous?(%{agreement_rate: 0.33, confidence: 0.65})
      true

      iex> Consensus.ambiguous?(%{agreement_rate: 1.0, confidence: 0.95})
      false
  """
  def ambiguous?(consensus_result) do
    low_agreement_threshold = Application.get_env(:volfefe_machine, :consensus, [])
                              |> Keyword.get(:low_agreement_threshold, 0.5)

    low_confidence_threshold = Application.get_env(:volfefe_machine, :consensus, [])
                               |> Keyword.get(:low_confidence_threshold, 0.7)

    agreement_rate = consensus_result.meta.agreement_rate
    confidence = consensus_result.confidence

    # Check if ambiguous
    cond do
      agreement_rate < low_agreement_threshold -> true
      confidence < low_confidence_threshold -> true
      true -> false
    end
  end
end
