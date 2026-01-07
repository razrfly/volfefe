defmodule Mix.Tasks.Polymarket.Batches do
  @moduledoc """
  List Polymarket discovery batch history.

  Displays discovery batches matching the Discovery tab in /admin/polymarket.

  ## Usage

      # Recent batches (default limit 20)
      mix polymarket.batches

      # With custom limit
      mix polymarket.batches --limit 50

      # Verbose output
      mix polymarket.batches --verbose

  ## Options

      --limit     Maximum batches to show (default: 20)
      --verbose   Show full batch details including thresholds

  ## Examples

      $ mix polymarket.batches

      DISCOVERY BATCHES (10 total)
      ═══════════════════════════════════════════════════════════════

      #abc123 [COMPLETED]
         Started: 2h ago | Completed: 2h ago
         Candidates: 5 | Top Score: 0.89 | Median: 0.72
         Notes: Quick discovery run

      #def456 [COMPLETED]
         ...
  """

  use Mix.Task
  alias VolfefeMachine.Polymarket

  @shortdoc "List Polymarket discovery batches"

  @impl Mix.Task
  def run(args) do
    Mix.Task.run("app.start")

    {opts, _, _} = OptionParser.parse(args,
      switches: [
        limit: :integer,
        verbose: :boolean
      ],
      aliases: [l: :limit, v: :verbose]
    )

    batches = Polymarket.list_discovery_batches(limit: opts[:limit] || 20)

    print_batches(batches, opts[:verbose] || false)
  end

  defp print_batches([], _verbose) do
    Mix.shell().info("")
    Mix.shell().info("No discovery batches found.")
    Mix.shell().info("Run: mix polymarket.discover to create one.")
    Mix.shell().info("")
  end

  defp print_batches(batches, verbose) do
    Mix.shell().info("")
    Mix.shell().info("DISCOVERY BATCHES (#{length(batches)} total)")
    Mix.shell().info(String.duplicate("═", 65))
    Mix.shell().info("")

    Enum.each(batches, fn batch ->
      print_batch(batch, verbose)
    end)

    Mix.shell().info(String.duplicate("─", 65))
    Mix.shell().info("Run discovery: mix polymarket.discover")
    Mix.shell().info("")
  end

  defp print_batch(batch, verbose) do
    status = if batch.completed_at, do: "COMPLETED", else: "RUNNING"
    status_icon = if batch.completed_at, do: "✅", else: "🔄"

    batch_id = truncate(batch.batch_id, 12)
    Mix.shell().info("#{status_icon} ##{batch_id} [#{status}]")

    started = relative_time(batch.started_at)
    completed = if batch.completed_at, do: relative_time(batch.completed_at), else: "in progress"
    Mix.shell().info("   Started: #{started} | Completed: #{completed}")

    candidates = batch.candidates_generated || 0
    top_score = format_decimal(batch.top_candidate_score)
    median = format_decimal(batch.median_candidate_score)
    Mix.shell().info("   Candidates: #{candidates} | Top Score: #{top_score} | Median: #{median}")

    if batch.notes do
      Mix.shell().info("   Notes: #{truncate(batch.notes, 50)}")
    end

    if verbose do
      Mix.shell().info("   Markets Analyzed: #{batch.markets_analyzed || "N/A"}")
      Mix.shell().info("   Trades Scored: #{batch.trades_scored || "N/A"}")
      Mix.shell().info("   Anomaly Threshold: #{format_decimal(batch.anomaly_threshold)}")
      Mix.shell().info("   Probability Threshold: #{format_decimal(batch.probability_threshold)}")
    end

    Mix.shell().info("")
  end

  defp format_decimal(nil), do: "N/A"
  defp format_decimal(%Decimal{} = d), do: Decimal.round(d, 2) |> Decimal.to_string()
  defp format_decimal(f) when is_float(f), do: Float.round(f, 2) |> Float.to_string()
  defp format_decimal(n), do: "#{n}"

  defp relative_time(nil), do: "N/A"
  defp relative_time(%DateTime{} = dt) do
    seconds = DateTime.diff(DateTime.utc_now(), dt)
    format_relative_seconds(seconds)
  end
  defp relative_time(%NaiveDateTime{} = dt) do
    {:ok, datetime} = DateTime.from_naive(dt, "Etc/UTC")
    relative_time(datetime)
  end

  defp format_relative_seconds(seconds) when seconds < 0, do: "just now"
  defp format_relative_seconds(seconds) when seconds < 60, do: "#{seconds}s ago"
  defp format_relative_seconds(seconds) when seconds < 3600, do: "#{div(seconds, 60)}m ago"
  defp format_relative_seconds(seconds) when seconds < 86400, do: "#{div(seconds, 3600)}h ago"
  defp format_relative_seconds(seconds), do: "#{div(seconds, 86400)}d ago"

  defp truncate(nil, _), do: ""
  defp truncate(str, max_length) when is_binary(str) do
    if String.length(str) > max_length do
      String.slice(str, 0, max_length) <> "..."
    else
      str
    end
  end
end
