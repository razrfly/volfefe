defmodule VolfefeMachine.Ingestion.Importer do
  @moduledoc """
  Handles importing posts from external sources into the database.

  Transforms external data formats to our Content schema and handles:
  - HTML stripping
  - Datetime parsing
  - Metadata extraction
  - Duplicate detection (upsert logic)
  """

  alias VolfefeMachine.Content

  require Logger

  @doc """
  Import posts from Apify format into database.

  ## Parameters

    * `posts` - List of post maps from Apify API
    * `source_name` - Name of the source (e.g., "truth_social")

  ## Returns

    * `{:ok, stats}` - Import statistics map
    * `{:error, reason}` - If source not found or critical error

  ## Statistics

  Returns a map with:
    * `:total` - Total posts processed
    * `:imported` - Successfully imported
    * `:updated` - Updated existing posts
    * `:failed` - Failed imports
    * `:skipped` - Skipped duplicates
  """
  def import_posts(posts, source_name) when is_list(posts) do
    Logger.info("Starting import of #{length(posts)} posts for source: #{source_name}")

    with {:ok, source} <- get_source(source_name),
         {:ok, stats} <- import_all_posts(posts, source) do
      update_source_timestamp(source)
      Logger.info("Import complete: #{stats.imported} imported, #{stats.failed} failed")
      {:ok, stats}
    else
      {:error, reason} = error ->
        Logger.error("Import failed: #{inspect(reason)}")
        error
    end
  end

  @doc """
  Transform a single Apify post to our Content schema format.
  """
  def transform_apify_post(apify_post, source_id) do
    %{
      source_id: source_id,
      external_id: apify_post["id"],
      author: apify_post["username"],
      text: strip_html(apify_post["content"]),
      url: apify_post["url"],
      published_at: parse_datetime(apify_post["createdAt"]),
      meta: %{
        "engagement" => %{
          "favorites" => apify_post["favouritesCount"] || 0,
          "reblogs" => apify_post["reblogsCount"] || 0,
          "replies" => apify_post["repliesCount"] || 0
        },
        "language" => apify_post["language"],
        "has_media" => length(apify_post["mediaAttachments"] || []) > 0,
        "is_reply" => apify_post["inReplyToId"] != nil,
        "account_id" => apify_post["accountId"]
      }
    }
  end

  @doc """
  Strip HTML tags from content.

  Simple regex approach - replaces <tag>content</tag> with just content.
  Also decodes common HTML entities.
  """
  def strip_html(nil), do: nil
  def strip_html(""), do: ""

  def strip_html(html) when is_binary(html) do
    html
    # Remove HTML tags
    |> String.replace(~r/<[^>]+>/, "")
    # Decode common HTML entities
    |> String.replace("&lt;", "<")
    |> String.replace("&gt;", ">")
    |> String.replace("&amp;", "&")
    |> String.replace("&quot;", "\"")
    |> String.replace("&#39;", "'")
    |> String.replace("&nbsp;", " ")
    # Clean up whitespace
    |> String.trim()
  end

  @doc """
  Parse ISO 8601 datetime string to DateTime.
  """
  def parse_datetime(nil), do: nil

  def parse_datetime(iso_string) when is_binary(iso_string) do
    case DateTime.from_iso8601(iso_string) do
      {:ok, datetime, _offset} -> datetime
      {:error, _reason} -> nil
    end
  end

  # Private Functions

  defp get_source(source_name) do
    {:ok, Content.get_source_by_name!(source_name)}
  rescue
    Ecto.NoResultsError ->
      {:error, {:source_not_found, source_name}}
  end

  defp import_all_posts(posts, source) do
    initial_stats = %{
      total: length(posts),
      imported: 0,
      updated: 0,
      failed: 0,
      skipped: 0
    }

    stats =
      Enum.reduce(posts, initial_stats, fn post, acc ->
        import_single_post(post, source, acc)
      end)

    {:ok, stats}
  end

  defp import_single_post(post, source, stats) do
    attrs = transform_apify_post(post, source.id)

    case Content.create_or_update_content(attrs) do
      {:ok, _content} ->
        # Note: create_or_update_content doesn't tell us if it was insert or update
        # We'll count everything as "imported" for now
        %{stats | imported: stats.imported + 1}

      {:error, changeset} ->
        Logger.warning("Failed to import post #{post["id"]}: #{inspect(changeset.errors)}")
        %{stats | failed: stats.failed + 1}
    end
  end

  defp update_source_timestamp(source) do
    Content.touch_source_fetched!(source.id)
  rescue
    e ->
      Logger.warning("Failed to update source timestamp: #{inspect(e)}")
      :ok
  end
end
