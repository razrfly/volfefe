defmodule VolfefeMachine.Content do
  @moduledoc """
  Public API for the Content context.

  Manages external content sources and ingested content.
  All database access for sources/contents goes through this module.
  """

  alias VolfefeMachine.{Repo, Content.Source, Content.Content}
  import Ecto.Query

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
  Marks a content as classified.
  Used by Intelligence context after ML analysis.

  ## Examples

      iex> mark_as_classified(1)
      :ok
  """
  def mark_as_classified(content_id) do
    from(c in Content, where: c.id == ^content_id)
    |> Repo.update_all(set: [classified: true])

    :ok
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
