defmodule VolfefeMachine.ContentTest do
  use VolfefeMachine.DataCase

  alias VolfefeMachine.Content

  describe "sources" do
    @valid_source_attrs %{
      name: "test_source",
      adapter: "TestAdapter",
      base_url: "https://example.com"
    }
    @invalid_source_attrs %{}

    test "list_sources/0 returns all sources" do
      {:ok, source} = Content.create_source(@valid_source_attrs)
      sources = Content.list_sources()
      assert length(sources) == 1
      assert hd(sources).id == source.id
    end

    test "get_source!/1 returns the source with given id" do
      {:ok, source} = Content.create_source(@valid_source_attrs)
      assert Content.get_source!(source.id).id == source.id
    end

    test "get_source_by_name!/1 returns the source with given name" do
      {:ok, source} = Content.create_source(@valid_source_attrs)
      found = Content.get_source_by_name!(source.name)
      assert found.id == source.id
      assert found.name == "test_source"
    end

    test "create_source/1 with valid data creates a source" do
      assert {:ok, source} = Content.create_source(@valid_source_attrs)
      assert source.name == "test_source"
      assert source.adapter == "TestAdapter"
      assert source.base_url == "https://example.com"
      assert source.enabled == true
    end

    test "create_source/1 with invalid data returns error changeset" do
      assert {:error, %Ecto.Changeset{}} = Content.create_source(@invalid_source_attrs)
    end

    test "create_source/1 enforces unique name constraint" do
      {:ok, _source} = Content.create_source(@valid_source_attrs)
      assert {:error, %Ecto.Changeset{}} = Content.create_source(@valid_source_attrs)
    end

    test "touch_source_fetched!/1 updates last_fetched_at" do
      {:ok, source} = Content.create_source(@valid_source_attrs)
      assert source.last_fetched_at == nil

      Content.touch_source_fetched!(source.id)

      updated = Content.get_source!(source.id)
      assert updated.last_fetched_at != nil
    end
  end

  describe "contents" do
    setup do
      {:ok, source} = Content.create_source(%{name: "test", adapter: "TestAdapter"})
      {:ok, source: source}
    end

    @valid_content_attrs %{
      external_id: "12345",
      author: "testuser",
      text: "Test content",
      url: "https://example.com/post/12345"
    }

    test "list_contents/0 returns all contents", %{source: source} do
      attrs = Map.put(@valid_content_attrs, :source_id, source.id)
      {:ok, content} = Content.create_or_update_content(attrs)

      contents = Content.list_contents()
      assert length(contents) == 1
      assert hd(contents).id == content.id
    end

    test "list_contents/1 filters by classified flag", %{source: source} do
      {:ok, _c1} =
        Content.create_or_update_content(%{
          source_id: source.id,
          external_id: "1",
          classified: false
        })

      {:ok, _c2} =
        Content.create_or_update_content(%{
          source_id: source.id,
          external_id: "2",
          classified: true
        })

      unclassified = Content.list_contents(classified: false)
      assert length(unclassified) == 1

      classified = Content.list_contents(classified: true)
      assert length(classified) == 1
    end

    test "list_contents/1 filters by source_id", %{source: source} do
      {:ok, source2} = Content.create_source(%{name: "source2", adapter: "Test"})

      {:ok, _c1} =
        Content.create_or_update_content(%{
          source_id: source.id,
          external_id: "1"
        })

      {:ok, _c2} =
        Content.create_or_update_content(%{
          source_id: source2.id,
          external_id: "2"
        })

      source1_contents = Content.list_contents(source_id: source.id)
      assert length(source1_contents) == 1

      source2_contents = Content.list_contents(source_id: source2.id)
      assert length(source2_contents) == 1
    end

    test "get_content!/1 returns the content with given id", %{source: source} do
      attrs = Map.put(@valid_content_attrs, :source_id, source.id)
      {:ok, content} = Content.create_or_update_content(attrs)
      assert Content.get_content!(content.id).id == content.id
    end

    test "create_or_update_content/1 with valid data creates content", %{source: source} do
      attrs = Map.put(@valid_content_attrs, :source_id, source.id)
      assert {:ok, content} = Content.create_or_update_content(attrs)
      assert content.external_id == "12345"
      assert content.author == "testuser"
      assert content.text == "Test content"
      assert content.classified == false
    end

    test "create_or_update_content/1 updates on conflict", %{source: source} do
      attrs = %{
        source_id: source.id,
        external_id: "12345",
        text: "Original text"
      }

      {:ok, first} = Content.create_or_update_content(attrs)

      # Update with same external_id
      updated_attrs = Map.merge(attrs, %{text: "Updated text", url: "https://updated.com"})
      {:ok, second} = Content.create_or_update_content(updated_attrs)

      assert first.id == second.id
      assert second.text == "Updated text"
      assert second.url == "https://updated.com"

      # Verify only one record exists
      all_contents = Content.list_contents()
      assert length(all_contents) == 1
    end

    test "create_or_update_content/1 with invalid data returns error changeset" do
      assert {:error, %Ecto.Changeset{}} = Content.create_or_update_content(%{})
    end

    test "mark_as_classified/1 updates classified flag", %{source: source} do
      attrs = Map.put(@valid_content_attrs, :source_id, source.id)
      {:ok, content} = Content.create_or_update_content(attrs)
      assert content.classified == false

      Content.mark_as_classified(content.id)

      updated = Content.get_content!(content.id)
      assert updated.classified == true
    end
  end
end
