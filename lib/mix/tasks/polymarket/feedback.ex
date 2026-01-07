defmodule Mix.Tasks.Polymarket.Feedback do
  @moduledoc """
  Run the feedback loop to improve pattern detection.

  The feedback loop:
  1. Marks newly confirmed insiders for training
  2. Recalculates insider baselines with new data
  3. Re-validates patterns against updated insider list
  4. Optionally re-scores all trades with updated baselines
  5. Runs discovery with updated scores

  ## Usage

      # Full feedback loop
      mix polymarket.feedback

      # Skip re-scoring (faster)
      mix polymarket.feedback --skip-rescore

      # Custom discovery limit
      mix polymarket.feedback --discovery-limit 50

      # With notes
      mix polymarket.feedback --notes "After confirming wallet X"

  ## Options

      --skip-rescore      Skip re-scoring trades (faster but less accurate)
      --discovery-limit   Max candidates from discovery (default: 100)
      --notes             Notes for this iteration

  ## Examples

      $ mix polymarket.feedback

      ═══════════════════════════════════════════════════════════════
      POLYMARKET FEEDBACK LOOP
      ═══════════════════════════════════════════════════════════════

      Starting iteration #4...

      Step 1: Mark insiders for training
         ✅ Marked 1 new insider(s)

      Step 2: Update baselines
         ✅ Updated 3 baseline metrics

      Step 3: Validate patterns
         ✅ Validated 8 patterns

      Step 4: Re-score trades
         ✅ Re-scored 2,199 trades

      Step 5: Run discovery
         ✅ Found 3 new candidates

      ═══════════════════════════════════════════════════════════════
      ITERATION COMPLETE
      ═══════════════════════════════════════════════════════════════

      IMPROVEMENTS
      ├─ Insiders: 3 → 4 (+1)
      ├─ Trained:  3 → 4 (+1)
      ├─ Best F1:  0.30 → 0.35 (+16.7%)
      └─ Candidates: 5 → 8 (+3)

  ## Workflow

  Typical workflow after confirming insiders:

      1. mix polymarket.confirm --id 5     # Confirm insider
      2. mix polymarket.feedback           # Run feedback loop
      3. mix polymarket.patterns --stats   # Check improved patterns
      4. mix polymarket.candidates         # See new candidates
  """

  use Mix.Task
  alias VolfefeMachine.Polymarket

  @shortdoc "Run feedback loop to improve patterns"

  @impl Mix.Task
  def run(args) do
    Mix.Task.run("app.start")

    {opts, _, _} = OptionParser.parse(args,
      switches: [
        skip_rescore: :boolean,
        discovery_limit: :integer,
        notes: :string
      ],
      aliases: [s: :skip_rescore, l: :discovery_limit, n: :notes]
    )

    print_header()

    rescore = not (opts[:skip_rescore] || false)
    discovery_limit = opts[:discovery_limit] || 100
    notes = opts[:notes] || "CLI feedback iteration"

    # Get pre-stats for comparison
    pre_stats = Polymarket.feedback_loop_stats()
    iteration = get_iteration_number()

    Mix.shell().info("Starting iteration ##{iteration}...")
    Mix.shell().info("")

    feedback_opts = [
      rescore_trades: rescore,
      discovery_limit: discovery_limit,
      notes: notes
    ]

    case Polymarket.run_feedback_loop(feedback_opts) do
      {:ok, result} ->
        print_steps(result.steps, rescore)
        print_results(result, pre_stats)

      {:error, reason} ->
        Mix.shell().error("")
        Mix.shell().error("❌ Feedback loop failed: #{inspect(reason)}")
        Mix.shell().info("")
    end

    print_footer()
  end

  defp print_header do
    Mix.shell().info("")
    Mix.shell().info(String.duplicate("═", 65))
    Mix.shell().info("POLYMARKET FEEDBACK LOOP")
    Mix.shell().info(String.duplicate("═", 65))
    Mix.shell().info("")
  end

  defp print_footer do
    Mix.shell().info(String.duplicate("─", 65))
    Mix.shell().info("View status: mix polymarket.status --all")
    Mix.shell().info("")
  end

  defp print_steps(steps, rescore) do
    Mix.shell().info("Step 1: Mark insiders for training")
    Mix.shell().info("   ✅ Marked #{steps.training_marked} new insider(s)")
    Mix.shell().info("")

    Mix.shell().info("Step 2: Update baselines")
    Mix.shell().info("   ✅ Updated #{steps.baselines_updated} baseline metrics")
    Mix.shell().info("")

    Mix.shell().info("Step 3: Validate patterns")
    Mix.shell().info("   ✅ Validated #{steps.patterns_validated} patterns")
    Mix.shell().info("")

    if rescore do
      Mix.shell().info("Step 4: Re-score trades")
      Mix.shell().info("   ✅ Re-scored #{format_number(steps.trades_rescored)} trades")
      Mix.shell().info("")

      Mix.shell().info("Step 5: Run discovery")
    else
      Mix.shell().info("Step 4: Run discovery (skipped re-scoring)")
    end

    Mix.shell().info("   ✅ Found #{steps.candidates_found} new candidates")
    Mix.shell().info("")
  end

  defp print_results(result, pre_stats) do
    post_stats = result.post_stats
    improvements = result.improvements

    Mix.shell().info(String.duplicate("═", 65))
    Mix.shell().info("ITERATION ##{result.iteration} COMPLETE")
    Mix.shell().info(String.duplicate("═", 65))
    Mix.shell().info("")

    Mix.shell().info("CHANGES")

    # Insiders
    pre_insiders = pre_stats.confirmed_insiders.total
    post_insiders = post_stats.confirmed_insiders.total
    insider_change = format_change(pre_insiders, post_insiders)
    Mix.shell().info("├─ Insiders: #{pre_insiders} → #{post_insiders} #{insider_change}")

    # Trained
    pre_trained = pre_stats.confirmed_insiders.trained
    post_trained = post_stats.confirmed_insiders.trained
    trained_change = format_change(pre_trained, post_trained)
    Mix.shell().info("├─ Trained:  #{pre_trained} → #{post_trained} #{trained_change}")

    # Best F1
    pre_f1 = pre_stats.patterns.best_f1_score || 0
    post_f1 = post_stats.patterns.best_f1_score || 0
    f1_change = format_percent_change(pre_f1, post_f1)
    Mix.shell().info("├─ Best F1:  #{format_decimal(pre_f1)} → #{format_decimal(post_f1)} #{f1_change}")

    # Candidates
    pre_candidates = pre_stats.discovery.total_candidates
    post_candidates = post_stats.discovery.total_candidates
    candidate_change = format_change(pre_candidates, post_candidates)
    Mix.shell().info("└─ Candidates: #{pre_candidates} → #{post_candidates} #{candidate_change}")

    Mix.shell().info("")

    # Show discovery batch info
    Mix.shell().info("Discovery batch: #{result.discovery_batch}")
    Mix.shell().info("")

    # Next steps
    if result.steps.candidates_found > 0 do
      Mix.shell().info("New candidates found! Next steps:")
      Mix.shell().info("- View: mix polymarket.candidates --status undiscovered")
      Mix.shell().info("- Investigate: mix polymarket.investigate --id ID")
    else
      Mix.shell().info("No new candidates found in this iteration.")
    end

    if post_stats.confirmed_insiders.untrained > 0 do
      Mix.shell().info("")
      Mix.shell().info("⚠️  #{post_stats.confirmed_insiders.untrained} untrained insider(s) remaining")
    end

    Mix.shell().info("")
  end

  defp get_iteration_number do
    stats = Polymarket.feedback_loop_stats()
    stats.discovery.total_batches + 1
  end

  defp format_change(pre, post) when pre == post, do: "(no change)"
  defp format_change(pre, post) when post > pre, do: "(+#{post - pre})"
  defp format_change(pre, post), do: "(#{post - pre})"

  defp format_percent_change(pre, post) when pre == 0 and post == 0, do: "(no change)"
  defp format_percent_change(pre, _post) when pre == 0, do: "(new)"
  defp format_percent_change(pre, post) do
    change = ((post - pre) / pre) * 100
    if change >= 0 do
      "(+#{Float.round(change, 1)}%)"
    else
      "(#{Float.round(change, 1)}%)"
    end
  end

  defp format_decimal(nil), do: "N/A"
  defp format_decimal(n) when is_float(n), do: Float.round(n, 4) |> Float.to_string()
  defp format_decimal(n), do: "#{n}"

  defp format_number(n) when is_integer(n) do
    n
    |> Integer.to_string()
    |> String.reverse()
    |> String.replace(~r/(\d{3})(?=\d)/, "\\1,")
    |> String.reverse()
  end
  defp format_number(n), do: "#{n}"
end
