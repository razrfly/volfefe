defmodule VolfefeMachine.Content do
  @moduledoc """
  Public API for the Content context.

  Manages external content sources and ingested content.
  All database access for sources/contents goes through this module.
  """

  alias VolfefeMachine.{Repo, Content.Source, Content.Content}
  alias VolfefeMachine.Workers.CaptureSnapshotsWorker
  import Ecto.Query
  require Logger

  # ========================================
  # Source Functions
  # ========================================

  @doc """
  Lists all sources.

  ## Examples

      iex> list_sources()
      [%Source{}, ...]
  """
  def list_sources do
    Repo.all(Source)
  end

  @doc """
  Gets a single source by ID.
  Raises if not found.

  ## Examples

      iex> get_source!(1)
      %Source{}

      iex> get_source!(999)
      ** (Ecto.NoResultsError)
  """
  def get_source!(id) do
    Repo.get!(Source, id)
  end

  @doc """
  Gets a source by name.
  Raises if not found.

  ## Examples

      iex> get_source_by_name!("truth_social")
      %Source{}

      iex> get_source_by_name!("unknown")
      ** (Ecto.NoResultsError)
  """
  def get_source_by_name!(name) do
    Repo.get_by!(Source, name: name)
  end

  @doc """
  Creates a new source.

  ## Examples

      iex> create_source(%{name: "truth_social", adapter: "TruthSocialAdapter"})
      {:ok, %Source{}}

      iex> create_source(%{})
      {:error, %Ecto.Changeset{}}
  """
  def create_source(attrs) do
    %Source{}
    |> Source.changeset(attrs)
    |> Repo.insert()
  end

  @doc """
  Updates the last_fetched_at timestamp for a source.

  ## Examples

      iex> touch_source_fetched!(1)
      :ok
  """
  def touch_source_fetched!(source_id) do
    from(s in Source, where: s.id == ^source_id)
    |> Repo.update_all(set: [last_fetched_at: DateTime.utc_now()])

    :ok
  end

  # ========================================
  # Content Functions
  # ========================================

  @doc """
  Lists contents with optional filters.

  ## Examples

      iex> list_contents()
      [%Content{}, ...]

      iex> list_contents(classified: false)
      [%Content{}, ...]

      iex> list_contents(source_id: 1)
      [%Content{}, ...]
  """
  def list_contents(filters \\ []) do
    Content
    |> apply_filters(filters)
    |> order_by([c], desc: c.published_at)
    |> Repo.all()
  end

  @doc """
  Gets a single content by ID.
  Returns nil if not found.

  ## Examples

      iex> get_content(1)
      %Content{}

      iex> get_content(999)
      nil
  """
  def get_content(id) do
    Repo.get(Content, id)
  end

  @doc """
  Gets a single content by ID.
  Raises if not found.

  ## Examples

      iex> get_content!(1)
      %Content{}

      iex> get_content!(999)
      ** (Ecto.NoResultsError)
  """
  def get_content!(id) do
    Repo.get!(Content, id)
  end

  @doc """
  Creates or updates content.
  Uses upsert logic to handle duplicates based on source_id + external_id.

  ## Examples

      iex> create_or_update_content(%{source_id: 1, external_id: "12345", text: "Test"})
      {:ok, %Content{}}

      iex> create_or_update_content(%{})
      {:error, %Ecto.Changeset{}}
  """
  def create_or_update_content(attrs) do
    %Content{}
    |> Content.changeset(attrs)
    |> Repo.insert(
      on_conflict: {:replace, [:text, :url, :published_at, :meta, :updated_at]},
      conflict_target: [:source_id, :external_id],
      returning: true
    )
  end

  @doc """
  Marks a content as classified and optionally enqueues market snapshot capture.
  Used by Intelligence context after ML analysis.

  ## Parameters

    * `content_id` - The content ID to mark as classified
    * `capture_snapshots` - Whether to auto-enqueue market snapshots (default: true)

  ## Examples

      # Default: classify and capture snapshots
      iex> mark_as_classified(1)
      :ok

      # Opt-out: classify only (useful for testing)
      iex> mark_as_classified(1, false)
      :ok
  """
  def mark_as_classified(content_id, capture_snapshots \\ true) do
    from(c in Content, where: c.id == ^content_id)
    |> Repo.update_all(set: [classified: true])

    if capture_snapshots do
      # Auto-trigger market snapshot capture (Phase 1 MVP)
      case %{content_id: content_id}
           |> CaptureSnapshotsWorker.new()
           |> Oban.insert() do
        {:ok, _job} ->
          Logger.info("Auto-enqueued market snapshot capture for content_id=#{content_id}")
          :ok

        {:error, reason} ->
          Logger.error("Failed to enqueue market snapshot capture for content_id=#{content_id}: #{inspect(reason)}")
          :ok  # Still return :ok so classification isn't blocked
      end
    else
      Logger.debug("Skipped market snapshot capture for content_id=#{content_id} (capture_snapshots=false)")
      :ok
    end
  end

  @doc """
  Marks a content as unclassified.
  Used when classifications are deleted.

  ## Examples

      iex> mark_as_unclassified(1)
      :ok
  """
  def mark_as_unclassified(content_id) do
    from(c in Content, where: c.id == ^content_id)
    |> Repo.update_all(set: [classified: false])

    :ok
  end

  @doc """
  Marks all content as unclassified.
  Used when bulk deleting all classifications.

  ## Examples

      iex> mark_all_as_unclassified()
      {:ok, 42}  # Returns count of updated records
  """
  def mark_all_as_unclassified do
    {count, _} =
      from(c in Content, where: c.classified == true)
      |> Repo.update_all(set: [classified: false])

    {:ok, count}
  end

  @doc """
  Synchronizes the classified status flag with actual classification records.
  Fixes any inconsistencies where the flag doesn't match database state.

  This is useful for:
  - Fixing data after manual database modifications
  - Recovering from race conditions
  - Periodic health checks

  ## Examples

      iex> synchronize_classified_status()
      {:ok, %{marked_classified: 5, marked_unclassified: 3}}
  """
  def synchronize_classified_status do
    require Logger

    # Find content marked as classified but has no classification records
    incorrectly_classified =
      from(c in Content,
        left_join: cl in assoc(c, :classification),
        where: c.classified == true and is_nil(cl.id),
        select: c.id
      )
      |> Repo.all()

    # Find content marked as unclassified but has classification records
    incorrectly_unclassified =
      from(c in Content,
        join: cl in assoc(c, :classification),
        where: c.classified == false,
        select: c.id
      )
      |> Repo.all()

    # Fix incorrectly classified (has flag but no records)
    {marked_unclassified, _} =
      if length(incorrectly_classified) > 0 do
        from(c in Content, where: c.id in ^incorrectly_classified)
        |> Repo.update_all(set: [classified: false])
      else
        {0, nil}
      end

    # Fix incorrectly unclassified (has records but no flag)
    {marked_classified, _} =
      if length(incorrectly_unclassified) > 0 do
        from(c in Content, where: c.id in ^incorrectly_unclassified)
        |> Repo.update_all(set: [classified: true])
      else
        {0, nil}
      end

    Logger.info(
      "Synchronized classified status: #{marked_classified} marked as classified, #{marked_unclassified} marked as unclassified"
    )

    {:ok, %{marked_classified: marked_classified, marked_unclassified: marked_unclassified}}
  end

  # ========================================
  # Private Helpers
  # ========================================

  defp apply_filters(query, []), do: query

  defp apply_filters(query, [{:classified, value} | rest]) do
    query
    |> where([c], c.classified == ^value)
    |> apply_filters(rest)
  end

  defp apply_filters(query, [{:source_id, value} | rest]) do
    query
    |> where([c], c.source_id == ^value)
    |> apply_filters(rest)
  end
end
