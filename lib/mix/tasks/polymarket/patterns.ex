defmodule Mix.Tasks.Polymarket.Patterns do
  @moduledoc """
  List Polymarket insider patterns with performance metrics.

  Displays patterns matching the Patterns tab in /admin/polymarket.

  ## Usage

      # All patterns with stats
      mix polymarket.patterns

      # Active patterns only
      mix polymarket.patterns --active

      # Show detailed conditions
      mix polymarket.patterns --verbose

  ## Options

      --active    Only show active patterns
      --verbose   Show full pattern conditions
      --stats     Show aggregated pattern statistics

  ## Examples

      $ mix polymarket.patterns

      INSIDER PATTERNS (8 total)
      ═══════════════════════════════════════════════════════════════

      #1 whale_correct [ACTIVE]
         Large correct trades with high confidence
         ├─ Precision: 0.85 | Recall: 0.62 | F1: 0.72
         ├─ True Positives: 12 | False Positives: 2
         └─ Lift: 4.2x

      #2 timing_extreme [ACTIVE]
         ...
  """

  use Mix.Task
  alias VolfefeMachine.Polymarket

  @shortdoc "List Polymarket insider patterns"

  @impl Mix.Task
  def run(args) do
    Mix.Task.run("app.start")

    {opts, _, _} = OptionParser.parse(args,
      switches: [
        active: :boolean,
        verbose: :boolean,
        stats: :boolean
      ],
      aliases: [a: :active, v: :verbose, s: :stats]
    )

    list_opts = [include_stats: true]
    list_opts = if opts[:active], do: Keyword.put(list_opts, :active_only, true), else: list_opts

    patterns = Polymarket.list_insider_patterns(list_opts)

    if opts[:stats] do
      print_stats()
    end

    print_patterns(patterns, opts[:verbose] || false)
  end

  defp print_stats do
    stats = Polymarket.pattern_stats()

    Mix.shell().info("")
    Mix.shell().info("PATTERN STATISTICS")
    Mix.shell().info(String.duplicate("═", 65))
    Mix.shell().info("")
    Mix.shell().info("Total Patterns:     #{stats.total_patterns}")
    Mix.shell().info("Active Patterns:    #{stats.active_patterns}")
    Mix.shell().info("Validated Patterns: #{stats.validated_patterns}")
    Mix.shell().info("Best Precision:     #{format_decimal(stats.best_precision)}")
    Mix.shell().info("Best F1 Score:      #{format_decimal(stats.best_f1)}")
    Mix.shell().info("Best Lift:          #{format_decimal(stats.best_lift)}x")
    Mix.shell().info("")
  end

  defp print_patterns([], _verbose) do
    Mix.shell().info("")
    Mix.shell().info("No patterns found.")
    Mix.shell().info("")
  end

  defp print_patterns(patterns, verbose) do
    Mix.shell().info("")
    Mix.shell().info("INSIDER PATTERNS (#{length(patterns)} total)")
    Mix.shell().info(String.duplicate("═", 65))
    Mix.shell().info("")

    Enum.each(patterns, fn pattern ->
      print_pattern(pattern, verbose)
    end)

    Mix.shell().info(String.duplicate("─", 65))
    Mix.shell().info("Use --verbose for full conditions")
    Mix.shell().info("")
  end

  defp print_pattern(pattern, verbose) do
    status = if pattern.is_active, do: "ACTIVE", else: "INACTIVE"
    status_icon = if pattern.is_active, do: "✅", else: "⏸️"

    Mix.shell().info("#{status_icon} ##{pattern.id} #{pattern.pattern_name} [#{status}]")

    if pattern.description do
      Mix.shell().info("   #{pattern.description}")
    end

    precision = format_decimal(pattern.precision)
    recall = format_decimal(pattern.recall)
    f1 = format_decimal(pattern.f1_score)
    Mix.shell().info("   ├─ Precision: #{precision} | Recall: #{recall} | F1: #{f1}")

    tp = pattern.true_positives || 0
    fp = pattern.false_positives || 0
    Mix.shell().info("   ├─ True Positives: #{tp} | False Positives: #{fp}")

    lift = format_decimal(pattern.lift)
    Mix.shell().info("   └─ Lift: #{lift}x")

    if verbose && pattern.conditions do
      Mix.shell().info("")
      Mix.shell().info("   CONDITIONS:")
      print_conditions(pattern.conditions)
    end

    Mix.shell().info("")
  end

  defp print_conditions(%{"rules" => rules, "logic" => logic} = conditions) do
    min_matches = Map.get(conditions, "min_matches", 1)
    Mix.shell().info("   Logic: #{logic} (min matches: #{min_matches})")

    Enum.each(rules, fn rule ->
      metric = rule["metric"]
      operator = rule["operator"]
      value = rule["value"]
      Mix.shell().info("   - #{metric} #{operator} #{inspect(value)}")
    end)
  end
  defp print_conditions(_), do: :ok

  defp format_decimal(nil), do: "N/A"
  defp format_decimal(%Decimal{} = d), do: Decimal.round(d, 4) |> Decimal.to_string()
  defp format_decimal(f) when is_float(f), do: Float.round(f, 4) |> Float.to_string()
  defp format_decimal(n), do: "#{n}"
end
