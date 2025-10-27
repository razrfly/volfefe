defmodule VolfefeMachine.Intelligence.ModelClassificationTest do
  use VolfefeMachine.DataCase

  alias VolfefeMachine.Intelligence.ModelClassification
  alias VolfefeMachine.{Content, Repo}

  describe "changeset/2" do
    setup do
      # Create a content item for testing
      {:ok, source} = Content.create_source(%{
        name: "Test Source",
        adapter: "test",
        base_url: "https://test.com",
        enabled: true
      })

      {:ok, content} = Content.create_or_update_content(%{
        source_id: source.id,
        external_id: "test-123",
        author: "test_author",
        text: "This is a test post",
        url: "https://test.com/post/123",
        published_at: ~U[2025-10-27 00:00:00Z]
      })

      %{content: content}
    end

    test "valid changeset with all required fields", %{content: content} do
      attrs = %{
        content_id: content.id,
        model_id: "distilbert",
        model_version: "distilbert-base-uncased-finetuned-sst-2-english",
        sentiment: "positive",
        confidence: 0.95,
        meta: %{
          "raw_scores" => %{"positive" => 0.95, "negative" => 0.05}
        }
      }

      changeset = ModelClassification.changeset(%ModelClassification{}, attrs)
      assert changeset.valid?
    end

    test "requires content_id", %{content: content} do
      attrs = %{
        model_id: "distilbert",
        model_version: "distilbert-base-uncased-finetuned-sst-2-english",
        sentiment: "positive",
        confidence: 0.95
      }

      changeset = ModelClassification.changeset(%ModelClassification{}, attrs)
      refute changeset.valid?
      assert %{content_id: ["can't be blank"]} = errors_on(changeset)
    end

    test "requires model_id", %{content: content} do
      attrs = %{
        content_id: content.id,
        model_version: "distilbert-base-uncased-finetuned-sst-2-english",
        sentiment: "positive",
        confidence: 0.95
      }

      changeset = ModelClassification.changeset(%ModelClassification{}, attrs)
      refute changeset.valid?
      assert %{model_id: ["can't be blank"]} = errors_on(changeset)
    end

    test "requires model_version", %{content: content} do
      attrs = %{
        content_id: content.id,
        model_id: "distilbert",
        sentiment: "positive",
        confidence: 0.95
      }

      changeset = ModelClassification.changeset(%ModelClassification{}, attrs)
      refute changeset.valid?
      assert %{model_version: ["can't be blank"]} = errors_on(changeset)
    end

    test "requires sentiment", %{content: content} do
      attrs = %{
        content_id: content.id,
        model_id: "distilbert",
        model_version: "distilbert-base-uncased-finetuned-sst-2-english",
        confidence: 0.95
      }

      changeset = ModelClassification.changeset(%ModelClassification{}, attrs)
      refute changeset.valid?
      assert %{sentiment: ["can't be blank"]} = errors_on(changeset)
    end

    test "requires confidence", %{content: content} do
      attrs = %{
        content_id: content.id,
        model_id: "distilbert",
        model_version: "distilbert-base-uncased-finetuned-sst-2-english",
        sentiment: "positive"
      }

      changeset = ModelClassification.changeset(%ModelClassification{}, attrs)
      refute changeset.valid?
      assert %{confidence: ["can't be blank"]} = errors_on(changeset)
    end

    test "validates sentiment is one of positive, negative, neutral", %{content: content} do
      attrs = %{
        content_id: content.id,
        model_id: "distilbert",
        model_version: "distilbert-base-uncased-finetuned-sst-2-english",
        sentiment: "invalid",
        confidence: 0.95
      }

      changeset = ModelClassification.changeset(%ModelClassification{}, attrs)
      refute changeset.valid?
      assert %{sentiment: ["is invalid"]} = errors_on(changeset)
    end

    test "validates confidence is between 0 and 1", %{content: content} do
      # Test below 0
      attrs = %{
        content_id: content.id,
        model_id: "distilbert",
        model_version: "distilbert-base-uncased-finetuned-sst-2-english",
        sentiment: "positive",
        confidence: -0.1
      }

      changeset = ModelClassification.changeset(%ModelClassification{}, attrs)
      refute changeset.valid?
      assert %{confidence: ["must be greater than or equal to 0.0"]} = errors_on(changeset)

      # Test above 1
      attrs = %{
        content_id: content.id,
        model_id: "distilbert",
        model_version: "distilbert-base-uncased-finetuned-sst-2-english",
        sentiment: "positive",
        confidence: 1.5
      }

      changeset = ModelClassification.changeset(%ModelClassification{}, attrs)
      refute changeset.valid?
      assert %{confidence: ["must be less than or equal to 1.0"]} = errors_on(changeset)
    end

    test "enforces unique constraint on content_id, model_id, model_version", %{content: content} do
      attrs = %{
        content_id: content.id,
        model_id: "distilbert",
        model_version: "distilbert-base-uncased-finetuned-sst-2-english",
        sentiment: "positive",
        confidence: 0.95
      }

      # Insert first record
      {:ok, _first} = %ModelClassification{}
      |> ModelClassification.changeset(attrs)
      |> Repo.insert()

      # Try to insert duplicate
      {:error, changeset} = %ModelClassification{}
      |> ModelClassification.changeset(attrs)
      |> Repo.insert()

      assert %{content_id: ["has already been taken"]} = errors_on(changeset)
    end

    test "allows same content_id with different model_id", %{content: content} do
      attrs1 = %{
        content_id: content.id,
        model_id: "distilbert",
        model_version: "distilbert-base-uncased-finetuned-sst-2-english",
        sentiment: "positive",
        confidence: 0.95
      }

      attrs2 = %{
        content_id: content.id,
        model_id: "finbert",
        model_version: "yiyanghkust/finbert-tone",
        sentiment: "neutral",
        confidence: 0.85
      }

      {:ok, _first} = %ModelClassification{}
      |> ModelClassification.changeset(attrs1)
      |> Repo.insert()

      {:ok, _second} = %ModelClassification{}
      |> ModelClassification.changeset(attrs2)
      |> Repo.insert()

      # Should have 2 records for this content
      count = Repo.aggregate(
        from(mc in ModelClassification, where: mc.content_id == ^content.id),
        :count,
        :id
      )
      assert count == 2
    end

    test "meta field is optional", %{content: content} do
      attrs = %{
        content_id: content.id,
        model_id: "distilbert",
        model_version: "distilbert-base-uncased-finetuned-sst-2-english",
        sentiment: "positive",
        confidence: 0.95
      }

      changeset = ModelClassification.changeset(%ModelClassification{}, attrs)
      assert changeset.valid?
    end

    test "meta field accepts map data", %{content: content} do
      attrs = %{
        content_id: content.id,
        model_id: "distilbert",
        model_version: "distilbert-base-uncased-finetuned-sst-2-english",
        sentiment: "positive",
        confidence: 0.95,
        meta: %{
          "raw_scores" => %{"positive" => 0.95, "negative" => 0.05},
          "processing" => %{"latency_ms" => 50},
          "quality" => %{"score_margin" => 0.9}
        }
      }

      {:ok, mc} = %ModelClassification{}
      |> ModelClassification.changeset(attrs)
      |> Repo.insert()

      assert mc.meta["raw_scores"]["positive"] == 0.95
      assert mc.meta["processing"]["latency_ms"] == 50
    end
  end

  describe "associations" do
    setup do
      {:ok, source} = Content.create_source(%{
        name: "Test Source",
        adapter: "test",
        base_url: "https://test.com",
        enabled: true
      })

      {:ok, content} = Content.create_or_update_content(%{
        source_id: source.id,
        external_id: "test-456",
        author: "test_author",
        text: "Association test",
        url: "https://test.com/post/456",
        published_at: ~U[2025-10-27 00:00:00Z]
      })

      {:ok, mc} = %ModelClassification{}
      |> ModelClassification.changeset(%{
        content_id: content.id,
        model_id: "distilbert",
        model_version: "distilbert-base-uncased-finetuned-sst-2-english",
        sentiment: "positive",
        confidence: 0.95
      })
      |> Repo.insert()

      %{content: content, model_classification: mc}
    end

    test "belongs_to content", %{model_classification: mc, content: content} do
      loaded = Repo.preload(mc, :content)
      assert loaded.content.id == content.id
      assert loaded.content.text == "Association test"
    end

    test "content has_many model_classifications", %{content: content} do
      # Add another model classification
      {:ok, _mc2} = %ModelClassification{}
      |> ModelClassification.changeset(%{
        content_id: content.id,
        model_id: "finbert",
        model_version: "yiyanghkust/finbert-tone",
        sentiment: "neutral",
        confidence: 0.90
      })
      |> Repo.insert()

      loaded = Repo.preload(content, :model_classifications)
      assert length(loaded.model_classifications) == 2
    end
  end
end
