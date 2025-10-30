defmodule VolfefeMachine.Workers.ImportContentWorker do
  @moduledoc """
  Oban worker for importing social media content from external sources.

  Handles the complete workflow:
  - Fetches posts from Apify API
  - Imports to database with upsert logic
  - Supports multiple import modes (newest, backfill, full)
  - Provides progress updates via job metadata

  ## Usage

      # Enqueue incremental import (newest mode)
      %{
        source: "truth_social",
        username: "realDonaldTrump",
        mode: "newest"
      }
      |> VolfefeMachine.Workers.ImportContentWorker.new()
      |> Oban.insert()

      # Enqueue backfill for date range
      %{
        source: "truth_social",
        username: "realDonaldTrump",
        mode: "backfill",
        date_range: %{start_date: "2025-10-01", end_date: "2025-10-31"},
        limit: 500
      }
      |> VolfefeMachine.Workers.ImportContentWorker.new()
      |> Oban.insert()

  ## Job Arguments

    * `:source` - Content source (e.g., "truth_social") (required)
    * `:username` - Username/profile to fetch (required)
    * `:mode` - Import mode: "newest", "backfill", "full" (required)
    * `:limit` - Max posts to fetch (optional, auto-calculated for "newest")
    * `:date_range` - Date range for backfill: %{start_date, end_date} (required for "backfill")
    * `:include_replies` - Include replies (optional, default: false)

  """

  use Oban.Worker,
    queue: :content_import,
    max_attempts: 2

  require Logger

  alias VolfefeMachine.Ingestion.{ApifyClient, Importer, ImportAnalyzer}

  @impl Oban.Worker
  def perform(%Oban.Job{args: args} = job) do
    source = Map.fetch!(args, "source")
    username = Map.fetch!(args, "username")
    mode = Map.fetch!(args, "mode")
    limit = calculate_limit(mode, Map.get(args, "limit"), source, username)
    include_replies = Map.get(args, "include_replies", false)
    date_range = parse_date_range(Map.get(args, "date_range"))

    Logger.info("Starting content import: source=#{source}, username=#{username}, mode=#{mode}, limit=#{limit}")

    # Update job metadata with status
    {:ok, _job} = update_job_meta(job, %{status: "fetching", limit: limit})

    # Step 1: Fetch from Apify
    case ApifyClient.fetch_posts(username,
           max_posts: limit,
           include_replies: include_replies
         ) do
      {:ok, posts} ->
        Logger.info("Fetched #{length(posts)} posts from Apify")
        {:ok, _job} = update_job_meta(job, %{status: "importing", fetched: length(posts)})

        # Filter by date range if backfill mode
        filtered_posts =
          if mode == "backfill" and date_range do
            filter_by_date_range(posts, date_range)
          else
            posts
          end

        Logger.info("Importing #{length(filtered_posts)} posts (#{length(posts) - length(filtered_posts)} filtered out)")

        # Step 2: Import to database
        case Importer.import_posts(filtered_posts, source) do
          {:ok, stats} ->
            Logger.info("Import complete: imported=#{stats.imported}, failed=#{stats.failed}")

            {:ok, _job} =
              update_job_meta(job, %{
                status: "completed",
                imported: stats.imported,
                failed: stats.failed,
                total: stats.total
              })

            :ok

          {:error, reason} ->
            Logger.error("Import failed: #{inspect(reason)}")
            {:error, reason}
        end

      {:error, reason} ->
        Logger.error("Fetch failed: #{inspect(reason)}")
        {:error, reason}
    end
  end

  # Private functions

  defp calculate_limit("newest", nil, source, username) do
    case ImportAnalyzer.calculate_incremental_limit(source, username) do
      {:ok, calc} -> calc.recommended_limit
      {:error, _} -> 100
    end
  end

  defp calculate_limit(_mode, nil, _source, _username), do: 100
  defp calculate_limit(_mode, limit, _source, _username) when is_integer(limit), do: limit
  defp calculate_limit(_mode, limit, _source, _username) when is_binary(limit), do: String.to_integer(limit)

  defp parse_date_range(nil), do: nil

  defp parse_date_range(%{"start_date" => start_str, "end_date" => end_str}) do
    with {:ok, start_date} <- Date.from_iso8601(start_str),
         {:ok, end_date} <- Date.from_iso8601(end_str) do
      {start_date, end_date}
    else
      _ -> nil
    end
  end

  defp filter_by_date_range(posts, {start_date, end_date}) do
    Enum.filter(posts, fn post ->
      case Importer.parse_datetime(post["createdAt"]) do
        nil ->
          false

        datetime ->
          post_date = DateTime.to_date(datetime)
          Date.compare(post_date, start_date) != :lt and Date.compare(post_date, end_date) != :gt
      end
    end)
  end

  defp update_job_meta(%Oban.Job{id: job_id}, metadata) do
    import Ecto.Query

    from(j in Oban.Job, where: j.id == ^job_id, select: j)
    |> VolfefeMachine.Repo.one()
    |> case do
      nil ->
        {:ok, nil}

      job ->
        updated_meta = Map.merge(job.meta || %{}, metadata)

        job
        |> Ecto.Changeset.change(%{meta: updated_meta})
        |> VolfefeMachine.Repo.update()
    end
  end
end
