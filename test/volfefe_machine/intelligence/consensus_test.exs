defmodule VolfefeMachine.Intelligence.ConsensusTest do
  use VolfefeMachine.DataCase

  alias VolfefeMachine.Intelligence.Consensus

  describe "calculate/1" do
    test "calculates consensus with all models agreeing" do
      model_results = [
        %{model_id: "distilbert", sentiment: "negative", confidence: 0.95},
        %{model_id: "twitter_roberta", sentiment: "negative", confidence: 0.85},
        %{model_id: "finbert", sentiment: "negative", confidence: 0.90}
      ]

      assert {:ok, result} = Consensus.calculate(model_results)
      assert result.sentiment == "negative"
      assert result.confidence > 0.0
      assert result.model_version == "consensus_v1.0"
      assert result.meta.agreement_rate == 1.0
      assert result.meta.consensus_method == "weighted_vote"
      assert length(result.meta.models_used) == 3
    end

    test "calculates consensus with 2-1 split" do
      model_results = [
        %{model_id: "distilbert", sentiment: "negative", confidence: 0.95},
        %{model_id: "twitter_roberta", sentiment: "negative", confidence: 0.85},
        %{model_id: "finbert", sentiment: "neutral", confidence: 0.80}
      ]

      assert {:ok, result} = Consensus.calculate(model_results)
      assert result.sentiment == "negative"
      assert result.meta.agreement_rate == 0.67
    end

    test "uses weighted voting - higher weights win" do
      # DistilBERT (0.4) + Twitter-RoBERTa (0.4) = 0.8 weight for negative
      # FinBERT (0.2) = 0.2 weight for neutral
      model_results = [
        %{model_id: "distilbert", sentiment: "negative", confidence: 1.0},
        %{model_id: "twitter_roberta", sentiment: "negative", confidence: 1.0},
        %{model_id: "finbert", sentiment: "neutral", confidence: 1.0}
      ]

      assert {:ok, result} = Consensus.calculate(model_results)
      assert result.sentiment == "negative"

      # Weighted score: (1.0 * 0.4) + (1.0 * 0.4) = 0.8
      # Normalized: 0.8 / 1.0 (total weight) = 0.8
      assert result.confidence == 0.8
    end

    test "handles 3-way disagreement" do
      model_results = [
        %{model_id: "distilbert", sentiment: "positive", confidence: 0.90},
        %{model_id: "twitter_roberta", sentiment: "negative", confidence: 0.85},
        %{model_id: "finbert", sentiment: "neutral", confidence: 0.95}
      ]

      assert {:ok, result} = Consensus.calculate(model_results)
      # Should still calculate consensus based on weights
      assert result.sentiment in ["positive", "negative", "neutral"]
      assert result.meta.agreement_rate == 0.33
      assert result.meta.total_models == 3
    end

    test "returns error when no successful models" do
      model_results = [
        %{model_id: "distilbert", error: "Failed to load"},
        %{model_id: "twitter_roberta", error: "Timeout"},
        %{model_id: "finbert", error: "Network error"}
      ]

      assert {:error, :no_successful_models} = Consensus.calculate(model_results)
    end

    test "filters out failed models and calculates with remaining" do
      model_results = [
        %{model_id: "distilbert", sentiment: "negative", confidence: 0.95},
        %{model_id: "twitter_roberta", error: "Timeout"},
        %{model_id: "finbert", sentiment: "negative", confidence: 0.90}
      ]

      assert {:ok, result} = Consensus.calculate(model_results)
      assert result.sentiment == "negative"
      assert result.meta.total_models == 2
      assert result.meta.agreement_rate == 1.0
      assert "twitter_roberta" in result.meta.failed_models
    end

    test "includes model votes with weights and scores" do
      model_results = [
        %{model_id: "distilbert", sentiment: "negative", confidence: 0.95},
        %{model_id: "twitter_roberta", sentiment: "negative", confidence: 0.85},
        %{model_id: "finbert", sentiment: "neutral", confidence: 0.90}
      ]

      assert {:ok, result} = Consensus.calculate(model_results)

      votes = result.meta.model_votes
      assert length(votes) == 3

      # Check structure of votes
      distilbert_vote = Enum.find(votes, fn v -> v.model_id == "distilbert" end)
      assert distilbert_vote.sentiment == "negative"
      assert distilbert_vote.confidence == 0.95
      assert distilbert_vote.weight == 0.4
      assert distilbert_vote.weighted_score == 0.38  # 0.95 * 0.4
    end

    test "includes weighted scores for all sentiments" do
      model_results = [
        %{model_id: "distilbert", sentiment: "negative", confidence: 0.95},
        %{model_id: "twitter_roberta", sentiment: "negative", confidence: 0.85},
        %{model_id: "finbert", sentiment: "neutral", confidence: 0.90}
      ]

      assert {:ok, result} = Consensus.calculate(model_results)

      weighted_scores = result.meta.weighted_scores
      assert is_map(weighted_scores)
      assert Map.has_key?(weighted_scores, "negative")
      assert Map.has_key?(weighted_scores, "neutral")

      # negative: (0.95 * 0.4) + (0.85 * 0.4) = 0.72
      # neutral: (0.90 * 0.2) = 0.18
      assert weighted_scores["negative"] > weighted_scores["neutral"]
    end

    test "normalizes confidence to 0-1 range" do
      model_results = [
        %{model_id: "distilbert", sentiment: "positive", confidence: 0.50},
        %{model_id: "twitter_roberta", sentiment: "positive", confidence: 0.50},
        %{model_id: "finbert", sentiment: "positive", confidence: 0.50}
      ]

      assert {:ok, result} = Consensus.calculate(model_results)

      # Total weighted score: (0.5 * 0.4) + (0.5 * 0.4) + (0.5 * 0.2) = 0.5
      # Normalized by total weight (1.0): 0.5 / 1.0 = 0.5
      assert result.confidence == 0.5
      assert result.confidence >= 0.0
      assert result.confidence <= 1.0
    end

    test "handles empty list" do
      assert {:error, :no_successful_models} = Consensus.calculate([])
    end
  end

  describe "ambiguous?/1" do
    test "detects ambiguous consensus with low agreement" do
      consensus_result = %{
        sentiment: "negative",
        confidence: 0.8,
        meta: %{
          agreement_rate: 0.33,  # Low agreement
          consensus_method: "weighted_vote"
        }
      }

      assert Consensus.ambiguous?(consensus_result) == true
    end

    test "detects ambiguous consensus with low confidence" do
      consensus_result = %{
        sentiment: "negative",
        confidence: 0.65,  # Low confidence
        meta: %{
          agreement_rate: 1.0,
          consensus_method: "weighted_vote"
        }
      }

      assert Consensus.ambiguous?(consensus_result) == true
    end

    test "non-ambiguous with high agreement and confidence" do
      consensus_result = %{
        sentiment: "negative",
        confidence: 0.9,
        meta: %{
          agreement_rate: 1.0,
          consensus_method: "weighted_vote"
        }
      }

      assert Consensus.ambiguous?(consensus_result) == false
    end

    test "non-ambiguous with moderate agreement and high confidence" do
      consensus_result = %{
        sentiment: "negative",
        confidence: 0.85,
        meta: %{
          agreement_rate: 0.67,
          consensus_method: "weighted_vote"
        }
      }

      assert Consensus.ambiguous?(consensus_result) == false
    end
  end
end
