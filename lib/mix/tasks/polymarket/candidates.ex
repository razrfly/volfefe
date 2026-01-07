defmodule Mix.Tasks.Polymarket.Candidates do
  @moduledoc """
  List Polymarket investigation candidates.

  Displays candidates matching the Candidates tab in /admin/polymarket.

  ## Usage

      # All candidates (default limit 50)
      mix polymarket.candidates

      # Filter by status
      mix polymarket.candidates --status undiscovered
      mix polymarket.candidates --status investigating

      # Filter by priority
      mix polymarket.candidates --priority critical

      # Custom limit
      mix polymarket.candidates --limit 100

  ## Options

      --status    Filter by status (undiscovered, investigating, confirmed_insider, cleared, dismissed)
      --priority  Filter by priority (critical, high, medium, low)
      --limit     Maximum candidates to show (default: 50)
      --verbose   Show full candidate details

  ## Examples

      $ mix polymarket.candidates --status undiscovered

      INVESTIGATION CANDIDATES (5 total)
      ═══════════════════════════════════════════════════════════════

      #1 [CRITICAL] Rank #1 - 0x348a...f2c1
         Status: undiscovered | Priority: critical
         Probability: 89.5% | Anomaly: 0.92
         Profit: $12,450 | Discovered: 2h ago
         Market: Will Trump win the 2024 election?

      #2 [HIGH] Rank #2 - 0x7b2e...a891
         ...
  """

  use Mix.Task
  alias VolfefeMachine.Polymarket

  @shortdoc "List Polymarket investigation candidates"

  @impl Mix.Task
  def run(args) do
    Mix.Task.run("app.start")

    {opts, _, _} = OptionParser.parse(args,
      switches: [
        status: :string,
        priority: :string,
        limit: :integer,
        verbose: :boolean
      ],
      aliases: [s: :status, p: :priority, v: :verbose, l: :limit]
    )

    list_opts = [limit: opts[:limit] || 50]
    list_opts = if opts[:status], do: Keyword.put(list_opts, :status, opts[:status]), else: list_opts
    list_opts = if opts[:priority], do: Keyword.put(list_opts, :priority, opts[:priority]), else: list_opts

    candidates = Polymarket.list_investigation_candidates(list_opts)

    print_candidates(candidates, opts[:verbose] || false)
  end

  defp print_candidates([], _verbose) do
    Mix.shell().info("")
    Mix.shell().info("No candidates found matching criteria.")
    Mix.shell().info("")
  end

  defp print_candidates(candidates, verbose) do
    Mix.shell().info("")
    Mix.shell().info("INVESTIGATION CANDIDATES (#{length(candidates)} total)")
    Mix.shell().info(String.duplicate("═", 65))
    Mix.shell().info("")

    Enum.each(candidates, fn candidate ->
      print_candidate(candidate, verbose)
    end)

    Mix.shell().info(String.duplicate("─", 65))
    Mix.shell().info("View details: mix polymarket.candidate --id ID")
    Mix.shell().info("")
  end

  defp print_candidate(c, verbose) do
    priority_icon = priority_icon(c.priority)
    wallet = format_wallet(c.wallet_address)

    Mix.shell().info("#{priority_icon} ##{c.id} [#{String.upcase(c.priority)}] Rank ##{c.discovery_rank} - #{wallet}")
    Mix.shell().info("   Status: #{c.status} | Priority: #{c.priority}")

    prob = format_probability(c.insider_probability)
    anomaly = format_decimal(c.anomaly_score)
    Mix.shell().info("   Probability: #{prob} | Anomaly: #{anomaly}")

    profit = format_profit(c.estimated_profit)
    Mix.shell().info("   Profit: #{profit} | Discovered: #{relative_time(c.discovered_at)}")

    if c.market_question do
      question = truncate(c.market_question, 50)
      Mix.shell().info("   Market: #{question}")
    end

    if verbose do
      Mix.shell().info("   Trade Size: #{format_decimal(c.trade_size)}")
      Mix.shell().info("   Hours Before Resolution: #{c.hours_before_resolution || "N/A"}")
      Mix.shell().info("   Trade Outcome: #{c.trade_outcome || "N/A"}")
      Mix.shell().info("   Was Correct: #{c.was_correct || "N/A"}")

      if c.investigation_started_at do
        Mix.shell().info("   Investigation Started: #{relative_time(c.investigation_started_at)}")
      end

      if c.resolved_at do
        Mix.shell().info("   Resolved: #{relative_time(c.resolved_at)} by #{c.resolved_by}")
      end

      if c.matched_patterns && length(c.matched_patterns) > 0 do
        Mix.shell().info("   Matched Patterns: #{Enum.join(c.matched_patterns, ", ")}")
      end
    end

    Mix.shell().info("")
  end

  defp priority_icon("critical"), do: "🚨"
  defp priority_icon("high"), do: "⚠️"
  defp priority_icon("medium"), do: "📊"
  defp priority_icon("low"), do: "ℹ️"
  defp priority_icon(_), do: "❓"

  defp format_wallet(nil), do: "Unknown"
  defp format_wallet(address) when byte_size(address) > 10 do
    "#{String.slice(address, 0, 6)}...#{String.slice(address, -4, 4)}"
  end
  defp format_wallet(address), do: address

  defp format_probability(nil), do: "N/A"
  defp format_probability(%Decimal{} = d) do
    "#{Decimal.round(Decimal.mult(d, 100), 1)}%"
  end
  defp format_probability(f) when is_float(f), do: "#{Float.round(f * 100, 1)}%"
  defp format_probability(n), do: "#{n}%"

  defp format_decimal(nil), do: "N/A"
  defp format_decimal(%Decimal{} = d), do: Decimal.to_string(d)
  defp format_decimal(n), do: "#{n}"

  defp format_profit(nil), do: "N/A"
  defp format_profit(%Decimal{} = d) do
    "$#{Decimal.round(d, 2) |> Decimal.to_string()}"
  end
  defp format_profit(n), do: "$#{n}"

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
