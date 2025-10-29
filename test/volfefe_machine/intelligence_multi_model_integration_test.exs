defmodule VolfefeMachine.IntelligenceMultiModelIntegrationTest do
  use VolfefeMachine.DataCase

  alias VolfefeMachine.{Content, Intelligence, Repo}
  alias VolfefeMachine.Intelligence.{Classification, ModelClassification}

  @moduletag :integration

  describe "classify_content_multi_model/1 integration" do
    setup do
      {:ok, source} = Content.create_source(%{
        name: "Test Source",
        adapter: "test",
        base_url: "https://test.com",
        enabled: true
      })

      {:ok, content} = Content.create_or_update_content(%{
        source_id: source.id,
        external_id: "integration-test-1",
        author: "test_author",
        text: "This company is doing great! Stock prices are up and profits are strong.",
        url: "https://test.com/post/1",
        published_at: ~U[2025-10-27 00:00:00Z]
      })

      %{content: content}
    end

    @tag :slow
    test "classifies content with all 3 models", %{content: content} do
      assert {:ok, result} = Intelligence.classify_content_multi_model(content.id)

      # Check result structure
      assert Map.has_key?(result, :consensus)
      assert Map.has_key?(result, :model_results)
      assert Map.has_key?(result, :metadata)

      # Check consensus
      consensus = result.consensus
      assert consensus.sentiment in ["positive", "negative", "neutral"]
      assert consensus.confidence >= 0.0
      assert consensus.confidence <= 1.0
      assert consensus.model_version == "consensus_v1.0"

      # Check model results
      assert length(result.model_results) == 3
      model_ids = Enum.map(result.model_results, & &1.model_id)
      assert "distilbert" in model_ids
      assert "twitter_roberta" in model_ids
      assert "finbert" in model_ids

      # Check metadata
      assert result.metadata.total_latency_ms > 0
      assert result.metadata.successful_models == 3
    end

    @tag :slow
    test "stores model classifications in database", %{content: content} do
      assert {:ok, _result} = Intelligence.classify_content_multi_model(content.id)

      # Check that 3 model classifications were created
      model_classifications = Repo.all(
        from mc in ModelClassification,
        where: mc.content_id == ^content.id
      )

      assert length(model_classifications) == 3

      # Verify each has required fields
      for mc <- model_classifications do
        assert mc.model_id in ["distilbert", "twitter_roberta", "finbert"]
        assert mc.sentiment in ["positive", "negative", "neutral"]
        assert mc.confidence >= 0.0
        assert mc.confidence <= 1.0
        assert is_map(mc.meta)
      end
    end

    @tag :slow
    test "stores consensus classification in database", %{content: content} do
      assert {:ok, _result} = Intelligence.classify_content_multi_model(content.id)

      # Check that consensus classification was created
      consensus = Intelligence.get_classification_by_content(content.id)

      assert consensus != nil
      assert consensus.model_version == "consensus_v1.0"
      assert consensus.sentiment in ["positive", "negative", "neutral"]
      assert is_map(consensus.meta)
      assert consensus.meta["consensus_method"] == "weighted_vote"
    end

    @tag :slow
    test "updates existing consensus on re-classification", %{content: content} do
      # First classification
      assert {:ok, result1} = Intelligence.classify_content_multi_model(content.id)
      consensus1_id = result1.consensus.id

      # Second classification (should update, not create new)
      assert {:ok, result2} = Intelligence.classify_content_multi_model(content.id)
      consensus2_id = result2.consensus.id

      # Should be same ID (updated, not inserted)
      assert consensus1_id == consensus2_id

      # Should have 3 model classifications (upserted on second run due to unique constraint)
      # The unique constraint on (content_id, model_id, model_version) means second run
      # updates existing records rather than creating new ones
      count = Repo.aggregate(
        from(mc in ModelClassification, where: mc.content_id == ^content.id),
        :count,
        :id
      )
      assert count == 3
    end

    @tag :slow
    test "consensus metadata includes all required fields", %{content: content} do
      assert {:ok, result} = Intelligence.classify_content_multi_model(content.id)

      meta = result.consensus.meta
      assert meta.consensus_method == "weighted_vote"
      assert is_list(meta.models_used)
      assert meta.total_models == 3
      assert is_float(meta.agreement_rate)
      assert is_list(meta.model_votes)
      assert is_map(meta.weighted_scores)
    end

    test "returns error for non-existent content" do
      assert {:error, :content_not_found} = Intelligence.classify_content_multi_model(99999)
    end

    test "returns error for content with no text" do
      {:ok, source} = Content.create_source(%{
        name: "Empty Text Source",
        adapter: "test",
        base_url: "https://test.com",
        enabled: true
      })

      {:ok, content} = Content.create_or_update_content(%{
        source_id: source.id,
        external_id: "no-text",
        author: "test_author",
        text: "",
        url: "https://test.com/post/empty",
        published_at: ~U[2025-10-27 00:00:00Z]
      })

      assert {:error, :no_text_to_classify} = Intelligence.classify_content_multi_model(content.id)
    end
  end

  describe "batch_classify_contents_multi_model/1 integration" do
    setup do
      {:ok, source} = Content.create_source(%{
        name: "Batch Test Source",
        adapter: "test",
        base_url: "https://test.com",
        enabled: true
      })

      {:ok, content1} = Content.create_or_update_content(%{
        source_id: source.id,
        external_id: "batch-1",
        author: "test_author",
        text: "Great news!",
        url: "https://test.com/post/batch1",
        published_at: ~U[2025-10-27 00:00:00Z]
      })

      {:ok, content2} = Content.create_or_update_content(%{
        source_id: source.id,
        external_id: "batch-2",
        author: "test_author",
        text: "Terrible results!",
        url: "https://test.com/post/batch2",
        published_at: ~U[2025-10-27 00:00:00Z]
      })

      %{content_ids: [content1.id, content2.id]}
    end

    @tag :slow
    test "classifies multiple content items", %{content_ids: content_ids} do
      results = Intelligence.batch_classify_contents_multi_model(content_ids)

      assert length(results) == 2
      assert Enum.all?(results, &match?({:ok, _}, &1))
    end
  end
end
