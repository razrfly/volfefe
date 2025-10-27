defmodule VolfefeMachine.Intelligence.MultiModelClientTest do
  use VolfefeMachine.DataCase

  alias VolfefeMachine.Intelligence.MultiModelClient

  describe "configured_models/0" do
    test "returns list of configured models from config" do
      models = MultiModelClient.configured_models()

      assert is_list(models)
      assert length(models) == 3

      # Check that all expected models are present
      model_ids = Enum.map(models, & &1.id)
      assert "distilbert" in model_ids
      assert "twitter_roberta" in model_ids
      assert "finbert" in model_ids
    end

    test "each model has required fields" do
      models = MultiModelClient.configured_models()

      for model <- models do
        assert Map.has_key?(model, :id)
        assert Map.has_key?(model, :name)
        assert Map.has_key?(model, :weight)
        assert Map.has_key?(model, :enabled)

        assert is_binary(model.id)
        assert is_binary(model.name)
        assert is_float(model.weight)
        assert is_boolean(model.enabled)
      end
    end

    test "model weights sum to 1.0" do
      models = MultiModelClient.configured_models()

      total_weight = models
      |> Enum.map(& &1.weight)
      |> Enum.sum()

      # Allow small floating point error
      assert_in_delta total_weight, 1.0, 0.01
    end
  end

  describe "model_weight/1" do
    test "returns weight for known model" do
      assert MultiModelClient.model_weight("distilbert") == 0.4
      assert MultiModelClient.model_weight("twitter_roberta") == 0.4
      assert MultiModelClient.model_weight("finbert") == 0.2
    end

    test "returns default weight for unknown model" do
      assert MultiModelClient.model_weight("unknown_model") == 1.0
    end
  end

  # Note: We don't test classify/1 in unit tests because it requires:
  # 1. Python environment with transformers library
  # 2. Model downloads (several GB)
  # 3. Significant execution time
  #
  # The classify/1 function is tested in:
  # - Integration tests with real models
  # - Manual testing during development
  # - Migration script validation
end
