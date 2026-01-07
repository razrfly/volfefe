defmodule Mix.Tasks.Polymarket.Discover do
  @moduledoc """
  Run discovery to find new insider candidates.

  Scans scored trades and generates investigation candidates based on
  anomaly scores and insider probability thresholds.

  ## Usage

      # Quick discovery with defaults
      mix polymarket.discover

      # Custom thresholds
      mix polymarket.discover --anomaly 0.6 --probability 0.5

      # Limit candidates
      mix polymarket.discover --limit 50

      # With notes
      mix polymarket.discover --notes "Daily scan"

  ## Options

      --anomaly       Anomaly score threshold (default: 0.5)
      --probability   Insider probability threshold (default: 0.4)
      --limit         Max candidates to generate (default: 100)
      --min-profit    Minimum estimated profit filter (default: 100)
      --notes         Notes for this discovery batch

  ## Examples

      $ mix polymarket.discover

      ═══════════════════════════════════════════════════════════════
      POLYMARKET DISCOVERY
      ═══════════════════════════════════════════════════════════════

      Starting discovery batch...
      Batch ID: discovery_1704672000_abc123

      Parameters:
      ├─ Anomaly Threshold:     0.5
      ├─ Probability Threshold: 0.4
      ├─ Limit:                 100
      └─ Min Profit:            $100

      Processing...

      ✅ Discovery complete!
         Candidates Found: 5
         Top Score: 0.89
         Median Score: 0.65

      Next steps:
      - View candidates: mix polymarket.candidates
      - Investigate: mix polymarket.investigate --id ID
  """

  use Mix.Task
  alias VolfefeMachine.Polymarket

  @shortdoc "Run discovery to find insider candidates"

  @impl Mix.Task
  def run(args) do
    Mix.Task.run("app.start")

    {opts, _, _} = OptionParser.parse(args,
      switches: [
        anomaly: :float,
        probability: :float,
        limit: :integer,
        min_profit: :integer,
        notes: :string
      ],
      aliases: [a: :anomaly, p: :probability, l: :limit, n: :notes]
    )

    print_header()

    anomaly = opts[:anomaly] || 0.5
    probability = opts[:probability] || 0.4
    limit = opts[:limit] || 100
    min_profit = opts[:min_profit] || 100
    notes = opts[:notes] || "CLI discovery run"

    Mix.shell().info("Starting discovery batch...")
    Mix.shell().info("")

    Mix.shell().info("Parameters:")
    Mix.shell().info("├─ Anomaly Threshold:     #{anomaly}")
    Mix.shell().info("├─ Probability Threshold: #{probability}")
    Mix.shell().info("├─ Limit:                 #{limit}")
    Mix.shell().info("└─ Min Profit:            $#{min_profit}")
    Mix.shell().info("")

    Mix.shell().info("Processing...")

    discovery_opts = [
      anomaly_threshold: Decimal.from_float(anomaly),
      probability_threshold: Decimal.from_float(probability),
      limit: limit,
      min_profit: min_profit,
      notes: notes
    ]

    case Polymarket.quick_discovery(discovery_opts) do
      {:ok, result} ->
        batch = result.batch
        Mix.shell().info("")
        Mix.shell().info("✅ Discovery complete!")
        Mix.shell().info("   Batch ID: #{batch.batch_id}")
        Mix.shell().info("   Candidates Found: #{result.candidates_created}")

        if result.candidates_created > 0 do
          Mix.shell().info("   Top Score: #{format_decimal(batch.top_candidate_score)}")
          Mix.shell().info("   Median Score: #{format_decimal(batch.median_candidate_score)}")
        end

        Mix.shell().info("")

        if result.candidates_created > 0 do
          Mix.shell().info("Next steps:")
          Mix.shell().info("- View candidates: mix polymarket.candidates")
          Mix.shell().info("- Investigate: mix polymarket.investigate --id ID")
        else
          Mix.shell().info("No new candidates found matching criteria.")
          Mix.shell().info("Try lowering thresholds or running feedback loop first.")
        end

        Mix.shell().info("")

      {:error, reason} ->
        Mix.shell().error("")
        Mix.shell().error("❌ Discovery failed: #{inspect(reason)}")
        Mix.shell().info("")
    end

    print_footer()
  end

  defp print_header do
    Mix.shell().info("")
    Mix.shell().info(String.duplicate("═", 65))
    Mix.shell().info("POLYMARKET DISCOVERY")
    Mix.shell().info(String.duplicate("═", 65))
    Mix.shell().info("")
  end

  defp print_footer do
    Mix.shell().info(String.duplicate("─", 65))
  end

  defp format_decimal(nil), do: "N/A"
  defp format_decimal(%Decimal{} = d), do: Decimal.round(d, 4) |> Decimal.to_string()
  defp format_decimal(f) when is_float(f), do: Float.round(f, 4) |> Float.to_string()
  defp format_decimal(n), do: "#{n}"
end
