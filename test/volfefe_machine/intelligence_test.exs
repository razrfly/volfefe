defmodule VolfefeMachine.IntelligenceTest do
  use VolfefeMachine.DataCase

  alias VolfefeMachine.Intelligence
  alias VolfefeMachine.Intelligence.Classification
  alias VolfefeMachine.Content

  describe "classifications" do
    setup do
      # Create a test source
      {:ok, source} = Content.create_source(%{
        name: "test_source",
        adapter: "TestAdapter"
      })

      # Create test content
      {:ok, content} = Content.create_or_update_content(%{
        source_id: source.id,
        external_id: "test_123",
        author: "test_author",
        text: "Test post about markets",
        url: "https://example.com/123",
        published_at: DateTime.utc_now()
      })

      %{source: source, content: content}
    end

    test "list_classifications/0 returns all classifications", %{content: content} do
      {:ok, classification} = Intelligence.create_classification(%{
        content_id: content.id,
        sentiment: "positive",
        confidence: 0.95,
        model_version: "finbert-tone-v1.0"
      })

      results = Intelligence.list_classifications()
      assert length(results) == 1
      assert hd(results).id == classification.id
    end

    test "get_classification!/1 returns the classification with given id", %{content: content} do
      {:ok, classification} = Intelligence.create_classification(%{
        content_id: content.id,
        sentiment: "positive",
        confidence: 0.95,
        model_version: "finbert-tone-v1.0"
      })

      assert Intelligence.get_classification!(classification.id).id == classification.id
    end

    test "get_classification_by_content/1 returns classification for content", %{content: content} do
      {:ok, classification} = Intelligence.create_classification(%{
        content_id: content.id,
        sentiment: "positive",
        confidence: 0.95,
        model_version: "finbert-tone-v1.0"
      })

      result = Intelligence.get_classification_by_content(content.id)
      assert result.id == classification.id
    end

    test "get_classification_by_content/1 returns nil when no classification exists" do
      assert Intelligence.get_classification_by_content(999) == nil
    end

    test "create_classification/1 with valid data creates a classification", %{content: content} do
      valid_attrs = %{
        content_id: content.id,
        sentiment: "positive",
        confidence: 0.95,
        model_version: "finbert-tone-v1.0",
        meta: %{
          "raw_scores" => %{
            "positive" => 0.95,
            "negative" => 0.02,
            "neutral" => 0.03
          }
        }
      }

      assert {:ok, %Classification{} = classification} = Intelligence.create_classification(valid_attrs)
      assert classification.sentiment == "positive"
      assert classification.confidence == 0.95
      assert classification.model_version == "finbert-tone-v1.0"
      assert classification.meta["raw_scores"]["positive"] == 0.95
    end

    test "create_classification/1 with invalid sentiment returns error changeset", %{content: content} do
      invalid_attrs = %{
        content_id: content.id,
        sentiment: "invalid",
        confidence: 0.95,
        model_version: "finbert-tone-v1.0"
      }

      assert {:error, %Ecto.Changeset{}} = Intelligence.create_classification(invalid_attrs)
    end

    test "create_classification/1 with invalid confidence returns error changeset", %{content: content} do
      invalid_attrs = %{
        content_id: content.id,
        sentiment: "positive",
        confidence: 1.5,
        model_version: "finbert-tone-v1.0"
      }

      assert {:error, %Ecto.Changeset{}} = Intelligence.create_classification(invalid_attrs)
    end

    test "create_classification/1 enforces unique constraint on content_id", %{content: content} do
      attrs = %{
        content_id: content.id,
        sentiment: "positive",
        confidence: 0.95,
        model_version: "finbert-tone-v1.0"
      }

      {:ok, _classification} = Intelligence.create_classification(attrs)

      assert {:error, changeset} = Intelligence.create_classification(attrs)
      assert "has already been taken" in errors_on(changeset).content_id
    end

    test "update_classification/2 with valid data updates the classification", %{content: content} do
      {:ok, classification} = Intelligence.create_classification(%{
        content_id: content.id,
        sentiment: "positive",
        confidence: 0.95,
        model_version: "finbert-tone-v1.0"
      })

      update_attrs = %{confidence: 0.99}

      assert {:ok, %Classification{} = classification} = Intelligence.update_classification(classification, update_attrs)
      assert classification.confidence == 0.99
    end

    test "update_classification/2 with invalid data returns error changeset", %{content: content} do
      {:ok, classification} = Intelligence.create_classification(%{
        content_id: content.id,
        sentiment: "positive",
        confidence: 0.95,
        model_version: "finbert-tone-v1.0"
      })

      assert {:error, %Ecto.Changeset{}} = Intelligence.update_classification(classification, %{sentiment: "invalid"})
    end

    test "delete_classification/1 deletes the classification", %{content: content} do
      {:ok, classification} = Intelligence.create_classification(%{
        content_id: content.id,
        sentiment: "positive",
        confidence: 0.95,
        model_version: "finbert-tone-v1.0"
      })

      assert {:ok, %Classification{}} = Intelligence.delete_classification(classification)
      assert_raise Ecto.NoResultsError, fn -> Intelligence.get_classification!(classification.id) end
    end

    test "list_by_sentiment/1 returns classifications with given sentiment", %{content: content} do
      {:ok, positive} = Intelligence.create_classification(%{
        content_id: content.id,
        sentiment: "positive",
        confidence: 0.95,
        model_version: "finbert-tone-v1.0"
      })

      # Create another content for negative classification
      {:ok, content2} = Content.create_or_update_content(%{
        source_id: content.source_id,
        external_id: "test_456",
        author: "test_author",
        text: "Negative post",
        url: "https://example.com/456",
        published_at: DateTime.utc_now()
      })

      {:ok, _negative} = Intelligence.create_classification(%{
        content_id: content2.id,
        sentiment: "negative",
        confidence: 0.90,
        model_version: "finbert-tone-v1.0"
      })

      results = Intelligence.list_by_sentiment("positive")
      assert length(results) == 1
      assert hd(results).id == positive.id
    end

    test "list_high_confidence/1 returns classifications above threshold", %{content: content} do
      {:ok, high} = Intelligence.create_classification(%{
        content_id: content.id,
        sentiment: "positive",
        confidence: 0.95,
        model_version: "finbert-tone-v1.0"
      })

      # Create another content for low confidence classification
      {:ok, content2} = Content.create_or_update_content(%{
        source_id: content.source_id,
        external_id: "test_789",
        author: "test_author",
        text: "Low confidence post",
        url: "https://example.com/789",
        published_at: DateTime.utc_now()
      })

      {:ok, _low} = Intelligence.create_classification(%{
        content_id: content2.id,
        sentiment: "neutral",
        confidence: 0.60,
        model_version: "finbert-tone-v1.0"
      })

      results = Intelligence.list_high_confidence(0.9)
      assert length(results) == 1
      assert hd(results).id == high.id
    end
  end

  describe "classify_content/1" do
    setup do
      # Create a test source
      {:ok, source} = Content.create_source(%{
        name: "test_source",
        adapter: "TestAdapter"
      })

      %{source: source}
    end

    test "returns error when content not found" do
      assert {:error, :content_not_found} = Intelligence.classify_content(999)
    end

    test "returns error when content has no text", %{source: source} do
      {:ok, content} = Content.create_or_update_content(%{
        source_id: source.id,
        external_id: "test_no_text",
        author: "test_author",
        text: nil,
        url: "https://example.com/no_text",
        published_at: DateTime.utc_now()
      })

      assert {:error, :no_text_to_classify} = Intelligence.classify_content(content.id)
    end

    test "returns error when content has empty text", %{source: source} do
      {:ok, content} = Content.create_or_update_content(%{
        source_id: source.id,
        external_id: "test_empty_text",
        author: "test_author",
        text: "",
        url: "https://example.com/empty_text",
        published_at: DateTime.utc_now()
      })

      assert {:error, :no_text_to_classify} = Intelligence.classify_content(content.id)
    end

    # Note: Testing actual FinBERT integration requires Python environment setup
    # These tests will be expanded once the Python service is running
  end
end
