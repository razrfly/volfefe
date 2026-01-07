defmodule Mix.Tasks.Polymarket.Candidate do
  @moduledoc """
  View details for a specific investigation candidate.

  Displays full candidate information matching the UI detail view.

  ## Usage

      # View candidate by ID
      mix polymarket.candidate --id 1

      # Show all available data
      mix polymarket.candidate --id 1 --verbose

  ## Options

      --id        Candidate ID (required)
      --verbose   Show all fields including anomaly breakdown

  ## Examples

      $ mix polymarket.candidate --id 1

      CANDIDATE #1 - 0x348a...f2c1
      ═══════════════════════════════════════════════════════════════

      STATUS
      ├─ Status:     investigating
      ├─ Priority:   critical
      ├─ Rank:       #1
      └─ Assigned:   analyst@example.com

      TRADE DETAILS
      ├─ Market:     Will Trump win the 2024 election?
      ├─ Trade Size: $12,450.00
      ├─ Outcome:    YES at 0.45
      ├─ Was Correct: Yes
      └─ Profit:     $8,250.00

      SIGNALS
      ├─ Insider Probability: 89.5%
      ├─ Anomaly Score:       0.92
      └─ Hours Before:        12.5h

      MATCHED PATTERNS
      ├─ whale_correct (0.95)
      └─ timing_extreme (0.88)
  """

  use Mix.Task
  alias VolfefeMachine.Polymarket

  @shortdoc "View candidate details"

  @impl Mix.Task
  def run(args) do
    Mix.Task.run("app.start")

    {opts, _, _} = OptionParser.parse(args,
      switches: [
        id: :integer,
        verbose: :boolean
      ],
      aliases: [v: :verbose]
    )

    case opts[:id] do
      nil ->
        Mix.shell().error("Error: --id is required")
        Mix.shell().info("Usage: mix polymarket.candidate --id ID")

      id ->
        case Polymarket.get_investigation_candidate(id) do
          nil ->
            Mix.shell().error("Candidate ##{id} not found")

          candidate ->
            print_candidate(candidate, opts[:verbose] || false)
        end
    end
  end

  defp print_candidate(c, verbose) do
    wallet = format_wallet(c.wallet_address)

    Mix.shell().info("")
    Mix.shell().info("CANDIDATE ##{c.id} - #{wallet}")
    Mix.shell().info(String.duplicate("═", 65))
    Mix.shell().info("")

    # Status section
    Mix.shell().info("STATUS")
    Mix.shell().info("├─ Status:     #{c.status}")
    Mix.shell().info("├─ Priority:   #{c.priority}")
    Mix.shell().info("├─ Rank:       ##{c.discovery_rank}")

    if c.assigned_to do
      Mix.shell().info("├─ Assigned:   #{c.assigned_to}")
    end

    if c.investigation_started_at do
      Mix.shell().info("├─ Started:    #{relative_time(c.investigation_started_at)}")
    end

    Mix.shell().info("└─ Discovered: #{relative_time(c.discovered_at)}")
    Mix.shell().info("")

    # Trade details
    Mix.shell().info("TRADE DETAILS")
    if c.market_question do
      Mix.shell().info("├─ Market:     #{truncate(c.market_question, 50)}")
    end
    Mix.shell().info("├─ Trade Size: #{format_money(c.trade_size)}")
    Mix.shell().info("├─ Outcome:    #{c.trade_outcome || "N/A"}")
    Mix.shell().info("├─ Was Correct: #{format_boolean(c.was_correct)}")
    Mix.shell().info("├─ Profit:     #{format_money(c.estimated_profit)}")
    Mix.shell().info("└─ Hours Before: #{format_hours(c.hours_before_resolution)}")
    Mix.shell().info("")

    # Signals
    Mix.shell().info("SIGNALS")
    Mix.shell().info("├─ Insider Probability: #{format_probability(c.insider_probability)}")
    Mix.shell().info("├─ Anomaly Score:       #{format_decimal(c.anomaly_score)}")

    if verbose && c.anomaly_breakdown do
      Mix.shell().info("└─ Anomaly Breakdown:")
      print_anomaly_breakdown(c.anomaly_breakdown)
    else
      Mix.shell().info("└─ (use --verbose for anomaly breakdown)")
    end
    Mix.shell().info("")

    # Matched patterns
    if has_patterns?(c.matched_patterns) do
      Mix.shell().info("MATCHED PATTERNS")
      print_patterns(c.matched_patterns)
      Mix.shell().info("")
    end

    # Resolution (if resolved)
    if c.resolved_at do
      Mix.shell().info("RESOLUTION")
      Mix.shell().info("├─ Resolved:   #{relative_time(c.resolved_at)}")
      Mix.shell().info("├─ By:         #{c.resolved_by || "N/A"}")

      if c.resolution_evidence do
        resolution = c.resolution_evidence["resolution"] || "unknown"
        Mix.shell().info("├─ Result:     #{resolution}")
      end

      if c.investigation_notes do
        Mix.shell().info("└─ Notes:      #{truncate(c.investigation_notes, 50)}")
      else
        Mix.shell().info("└─ Notes:      (none)")
      end
      Mix.shell().info("")
    end

    # Actions
    Mix.shell().info(String.duplicate("─", 65))
    case c.status do
      "undiscovered" ->
        Mix.shell().info("Actions: mix polymarket.investigate --id #{c.id}")

      "investigating" ->
        Mix.shell().info("Actions: mix polymarket.resolve --id #{c.id} --resolution confirmed_insider")
        Mix.shell().info("         mix polymarket.resolve --id #{c.id} --resolution cleared")

      _ ->
        Mix.shell().info("Status: #{c.status} (no actions available)")
    end
    Mix.shell().info("")
  end

  defp print_anomaly_breakdown(breakdown) when is_map(breakdown) do
    items = Map.to_list(breakdown)
    count = length(items)
    items
    |> Enum.sort_by(fn {_k, v} -> -get_score_value(v) end)
    |> Enum.with_index()
    |> Enum.each(fn {{key, value}, idx} ->
      prefix = if idx == count - 1, do: "   └─", else: "   ├─"
      case value do
        %{"zscore" => zscore, "severity" => severity} ->
          Mix.shell().info("#{prefix} #{key}: #{severity} (z=#{format_decimal(zscore)})")
        %{"value" => val, "severity" => severity} ->
          Mix.shell().info("#{prefix} #{key}: #{severity} (#{format_decimal(val)})")
        %{"severity" => severity} ->
          Mix.shell().info("#{prefix} #{key}: #{severity}")
        n when is_number(n) ->
          Mix.shell().info("#{prefix} #{key}: #{format_decimal(n)}")
        _ ->
          Mix.shell().info("#{prefix} #{key}")
      end
    end)
  end
  defp print_anomaly_breakdown(_), do: :ok

  defp get_score_value(%{"zscore" => z}), do: abs(to_float(z))
  defp get_score_value(%{"value" => v}), do: abs(to_float(v))
  defp get_score_value(n) when is_number(n), do: abs(n)
  defp get_score_value(_), do: 0

  defp has_patterns?(nil), do: false
  defp has_patterns?(patterns) when is_list(patterns), do: length(patterns) > 0
  defp has_patterns?(patterns) when is_map(patterns), do: map_size(patterns) > 0
  defp has_patterns?(_), do: false

  defp print_patterns(patterns) when is_list(patterns) do
    count = length(patterns)
    patterns
    |> Enum.with_index()
    |> Enum.each(fn {pattern, idx} ->
      prefix = if idx == count - 1, do: "└─", else: "├─"
      case pattern do
        %{"name" => name, "score" => score} ->
          Mix.shell().info("#{prefix} #{name} (#{format_decimal(score)})")
        name when is_binary(name) ->
          Mix.shell().info("#{prefix} #{name}")
        _ ->
          Mix.shell().info("#{prefix} #{inspect(pattern)}")
      end
    end)
  end
  defp print_patterns(patterns) when is_map(patterns) do
    items = Map.to_list(patterns)
    count = length(items)
    items
    |> Enum.with_index()
    |> Enum.each(fn {{name, value}, idx} ->
      prefix = if idx == count - 1, do: "└─", else: "├─"
      case value do
        %{"zscore" => zscore, "severity" => severity} ->
          Mix.shell().info("#{prefix} #{name}: #{severity} (z=#{format_decimal(zscore)})")
        %{"score" => score} ->
          Mix.shell().info("#{prefix} #{name} (#{format_decimal(score)})")
        score when is_number(score) ->
          Mix.shell().info("#{prefix} #{name} (#{format_decimal(score)})")
        _ ->
          Mix.shell().info("#{prefix} #{name}")
      end
    end)
  end
  defp print_patterns(_), do: :ok

  defp to_float(%Decimal{} = d), do: Decimal.to_float(d)
  defp to_float(f) when is_float(f), do: f
  defp to_float(n) when is_integer(n), do: n * 1.0
  defp to_float(_), do: 0.0

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
  defp format_decimal(%Decimal{} = d), do: Decimal.round(d, 4) |> Decimal.to_string()
  defp format_decimal(f) when is_float(f), do: Float.round(f, 4) |> Float.to_string()
  defp format_decimal(n), do: "#{n}"

  defp format_money(nil), do: "N/A"
  defp format_money(%Decimal{} = d), do: "$#{Decimal.round(d, 2) |> Decimal.to_string()}"
  defp format_money(n), do: "$#{n}"

  defp format_hours(nil), do: "N/A"
  defp format_hours(h), do: "#{h}h"

  defp format_boolean(nil), do: "N/A"
  defp format_boolean(true), do: "Yes"
  defp format_boolean(false), do: "No"

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
