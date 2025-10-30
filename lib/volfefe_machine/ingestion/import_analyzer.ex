defmodule VolfefeMachine.Ingestion.ImportAnalyzer do
  @moduledoc """
  Analyzes import status, detects gaps, and provides recommendations
  for smart social media content importing.
  """

  import Ecto.Query
  alias VolfefeMachine.{Repo, Content}
  alias VolfefeMachine.Content.Content, as: ContentSchema

  require Logger

  @doc """
  Get comprehensive import statistics for a source and author.

  Returns a map with:
  - total_posts: Total number of posts
  - date_range: {first_date, last_date}
  - last_import: Timestamp of most recent post
  - estimated_new: Estimated new posts available
  - gaps: List of detected gaps
  - posting_stats: Average posts per day
  """
  def analyze_import_status(source_name, username) do
    with {:ok, source} <- get_source(source_name),
         {:ok, stats} <- get_basic_stats(source.id, username),
         {:ok, gaps} <- detect_gaps(source.id, username),
         {:ok, posting_stats} <- calculate_posting_stats(source.id, username) do
      {:ok,
       %{
         source: source_name,
         username: username,
         total_posts: stats.total_posts,
         date_range: stats.date_range,
         last_import: stats.last_import,
         estimated_new: estimate_new_posts(stats.last_import, posting_stats.avg_per_day),
         gaps: gaps,
         posting_stats: posting_stats
       }}
    end
  end

  @doc """
  Calculate how many posts to fetch for incremental import.

  Returns recommended fetch limit based on:
  - Days since last import
  - Average posting frequency
  - Safety buffer (20%)
  """
  def calculate_incremental_limit(source_name, username, opts \\ []) do
    buffer_multiplier = Keyword.get(opts, :buffer, 1.2)

    with {:ok, source} <- get_source(source_name),
         {:ok, stats} <- get_basic_stats(source.id, username),
         {:ok, posting_stats} <- calculate_posting_stats(source.id, username) do
      if stats.last_import do
        days_since = DateTime.diff(DateTime.utc_now(), stats.last_import, :day)
        estimated = ceil(days_since * posting_stats.avg_per_day * buffer_multiplier)
        recommended = max(10, min(estimated, 500))

        {:ok,
         %{
           days_since_last: days_since,
           estimated_new: estimated,
           recommended_limit: recommended,
           avg_posts_per_day: posting_stats.avg_per_day
         }}
      else
        # No previous imports, recommend starting small
        {:ok,
         %{
           days_since_last: nil,
           estimated_new: nil,
           recommended_limit: 100,
           avg_posts_per_day: 0,
           note: "No previous imports found, starting with default limit"
         }}
      end
    end
  end

  @doc """
  Detect gaps in content coverage.

  Returns list of gaps with:
  - gap_start: Start date of gap
  - gap_end: End date of gap
  - days: Number of days in gap
  - severity: :critical (>7 days), :major (3-7 days), :minor (<3 days)
  """
  def detect_gaps(source_id, username, opts \\ []) do
    min_gap_days = Keyword.get(opts, :min_gap_days, 2)

    query =
      from c in ContentSchema,
        where: c.source_id == ^source_id and c.author == ^username,
        order_by: [asc: c.published_at],
        select: c.published_at

    dates = Repo.all(query)

    if length(dates) < 2 do
      {:ok, []}
    else
      gaps =
        dates
        |> Enum.chunk_every(2, 1, :discard)
        |> Enum.map(fn [prev, current] ->
          days_between = DateTime.diff(current, prev, :day)

          if days_between >= min_gap_days do
            %{
              gap_start: DateTime.to_date(prev),
              gap_end: DateTime.to_date(current),
              days: days_between,
              severity: categorize_gap(days_between)
            }
          end
        end)
        |> Enum.reject(&is_nil/1)
        |> Enum.sort_by(& &1.days, :desc)

      {:ok, gaps}
    end
  end

  # Private Functions

  defp get_source(source_name) do
    source = Content.get_source_by_name!(source_name)
    {:ok, source}
  rescue
    Ecto.NoResultsError ->
      {:error, {:source_not_found, source_name}}
  end

  defp get_basic_stats(source_id, username) do
    query =
      from c in ContentSchema,
        where: c.source_id == ^source_id and c.author == ^username,
        select: %{
          total: count(c.id),
          first: min(c.published_at),
          last: max(c.published_at)
        }

    case Repo.one(query) do
      %{total: 0} ->
        {:ok,
         %{
           total_posts: 0,
           date_range: nil,
           last_import: nil
         }}

      %{total: total, first: first, last: last} ->
        {:ok,
         %{
           total_posts: total,
           date_range: {first, last},
           last_import: last
         }}

      _ ->
        {:error, :query_failed}
    end
  end

  defp calculate_posting_stats(source_id, username) do
    query =
      from c in ContentSchema,
        where: c.source_id == ^source_id and c.author == ^username,
        select: %{
          first: min(c.published_at),
          last: max(c.published_at),
          total: count(c.id)
        }

    case Repo.one(query) do
      %{total: 0} ->
        {:ok, %{avg_per_day: 0, total_days: 0}}

      %{first: first, last: last, total: total} when not is_nil(first) and not is_nil(last) ->
        days = max(1, DateTime.diff(last, first, :day))
        avg_per_day = Float.round(total / days, 2)

        {:ok, %{avg_per_day: avg_per_day, total_days: days}}

      _ ->
        {:ok, %{avg_per_day: 0, total_days: 0}}
    end
  end

  defp estimate_new_posts(nil, _avg_per_day), do: nil

  defp estimate_new_posts(last_import, avg_per_day) do
    days_since = DateTime.diff(DateTime.utc_now(), last_import, :day)
    ceil(days_since * avg_per_day)
  end

  defp categorize_gap(days) when days >= 7, do: :critical
  defp categorize_gap(days) when days >= 3, do: :major
  defp categorize_gap(_days), do: :minor

  @doc """
  Format analysis results for CLI display.
  """
  def format_status(analysis) do
    lines = [
      "",
      String.duplicate("=", 80),
      "📊 Import Status - #{String.upcase(analysis.source)} (@#{analysis.username})",
      String.duplicate("=", 80),
      "",
      "Content Statistics:",
      "  Total Posts: #{analysis.total_posts}",
      format_date_range(analysis.date_range),
      format_last_import(analysis.last_import, analysis.estimated_new),
      "",
      format_posting_stats(analysis.posting_stats),
      "",
      format_gaps(analysis.gaps),
      "",
      format_recommendations(analysis),
      ""
    ]

    Enum.join(lines, "\n")
  end

  defp format_date_range(nil), do: "  Date Range: No posts"

  defp format_date_range({first, last}) do
    "  Date Range: #{DateTime.to_date(first)} to #{DateTime.to_date(last)}"
  end

  defp format_last_import(nil, _), do: "  Last Import: Never"

  defp format_last_import(last_import, estimated_new) do
    now = DateTime.utc_now()
    diff = DateTime.diff(now, last_import, :second)

    time_ago =
      cond do
        diff < 3600 -> "#{div(diff, 60)} minutes ago"
        diff < 86400 -> "#{div(diff, 3600)} hours ago"
        true -> "#{div(diff, 86400)} days ago"
      end

    estimated_str = if estimated_new, do: " (~#{estimated_new} new posts estimated)", else: ""
    "  Last Import: #{last_import} (#{time_ago})#{estimated_str}"
  end

  defp format_posting_stats(%{avg_per_day: avg, total_days: days}) do
    "Posting Statistics:\n  Average: #{avg} posts/day (over #{days} days)"
  end

  defp format_gaps([]) do
    "Gap Analysis:\n  ✅ No significant gaps detected"
  end

  defp format_gaps(gaps) do
    critical = Enum.count(gaps, &(&1.severity == :critical))
    major = Enum.count(gaps, &(&1.severity == :major))
    minor = Enum.count(gaps, &(&1.severity == :minor))

    summary = "Gap Analysis:\n  Found #{length(gaps)} gap(s): #{critical} critical, #{major} major, #{minor} minor\n"

    largest_gaps =
      gaps
      |> Enum.take(3)
      |> Enum.map(fn gap ->
        icon =
          case gap.severity do
            :critical -> "🚨"
            :major -> "⚠️"
            :minor -> "ℹ️"
          end

        "  #{icon} #{gap.gap_start} to #{gap.gap_end} (#{gap.days} days)"
      end)
      |> Enum.join("\n")

    summary <> largest_gaps
  end

  defp format_recommendations(analysis) do
    recs = []

    # Recommend incremental import if there are estimated new posts
    recs =
      if analysis.estimated_new && analysis.estimated_new > 0 do
        limit = min(analysis.estimated_new * 2, 200)

        [
          "• Run: mix ingest.content --source #{analysis.source} --username #{analysis.username} --mode newest --limit #{limit}"
          | recs
        ]
      else
        recs
      end

    # Recommend backfill for critical gaps
    recs =
      case Enum.filter(analysis.gaps, &(&1.severity in [:critical, :major])) do
        [] ->
          recs

        [gap | _] ->
          [
            "• Run: mix ingest.content --source #{analysis.source} --username #{analysis.username} --mode backfill --date-range \"#{gap.gap_start} #{gap.gap_end}\""
            | recs
          ]
      end

    if length(recs) > 0 do
      "Recommendations:\n" <> Enum.join(Enum.reverse(recs), "\n")
    else
      "Recommendations:\n  ✅ Data looks complete! No action needed."
    end
  end
end
