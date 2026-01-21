defmodule Mix.Tasks.Polymarket.Promote do
  @moduledoc """
  Promote discovered wallets from reference cases to investigation candidates.

  After running discovery (`mix polymarket.discover --reference-case`), use this
  task to create investigation candidates from suspicious wallets.

  ## Usage

      # Promote wallets from a reference case
      mix polymarket.promote --reference-case "Nobel Peace Prize 2025"

      # With custom threshold
      mix polymarket.promote --reference-case "Case Name" --min-score 0.6

      # Preview only (don't create candidates)
      mix polymarket.promote --reference-case "Case Name" --dry-run

      # Limit number of candidates
      mix polymarket.promote --reference-case "Case Name" --limit 10

  ## Options

      --reference-case  Reference case name (required)
      --min-score       Minimum suspicion score (default: 0.4)
      --limit           Maximum candidates to create (default: 20)
      --priority        Force priority level: critical, high, medium, low
      --dry-run         Preview without creating candidates

  ## Workflow

      1. mix polymarket.discover --reference-case "Case Name"   # Find markets/wallets
      2. mix polymarket.confirm --reference-case "Case Name" --condition 0x...  # Confirm match
      3. mix polymarket.promote --reference-case "Case Name"    # Create candidates
      4. mix polymarket.candidates                              # Review candidates
      5. mix polymarket.investigate --id N                      # Start investigation

  ## Suspicion Score Thresholds

      Score >= 0.8  → Critical priority (immediate investigation)
      Score >= 0.6  → High priority (investigate soon)
      Score >= 0.4  → Medium priority (standard queue)
      Score < 0.4   → Low priority (monitor only)
  """

  use Mix.Task
  alias VolfefeMachine.Polymarket.{InsiderReferenceCase, PatternDiscovery}
  alias VolfefeMachine.Repo

  @shortdoc "Promote discovered wallets to investigation candidates"

  @impl Mix.Task
  def run(args) do
    Mix.Task.run("app.start")

    {opts, _, _} = OptionParser.parse(args,
      switches: [
        reference_case: :string,
        min_score: :float,
        limit: :integer,
        priority: :string,
        dry_run: :boolean
      ],
      aliases: [r: :reference_case, s: :min_score, l: :limit, p: :priority, d: :dry_run]
    )

    case_name = opts[:reference_case]

    unless case_name do
      Mix.shell().error("Error: --reference-case is required")
      Mix.shell().info("")
      Mix.shell().info("Usage: mix polymarket.promote --reference-case \"Case Name\"")
      Mix.shell().info("")
      Mix.shell().info("Run 'mix help polymarket.promote' for more options.")
      exit({:shutdown, 1})
    end

    case Repo.get_by(InsiderReferenceCase, case_name: case_name) do
      nil ->
        Mix.shell().error("Reference case not found: #{case_name}")
        Mix.shell().info("")
        list_available_cases()

      ref_case ->
        if opts[:dry_run] do
          show_promotion_preview(ref_case, opts)
        else
          promote_wallets(ref_case, opts)
        end
    end
  end

  defp show_promotion_preview(ref_case, opts) do
    min_score = opts[:min_score] || 0.4
    limit = opts[:limit] || 20

    Mix.shell().info("")
    Mix.shell().info("=== Promotion Preview ===")
    Mix.shell().info("")

    summary = PatternDiscovery.promotion_summary(ref_case)

    if summary.promotable do
      Mix.shell().info("Reference Case: #{ref_case.case_name}")
      Mix.shell().info("Total Wallets: #{summary.total_wallets}")
      Mix.shell().info("Has Condition ID: #{if summary.has_condition_id, do: "Yes", else: "No"}")
      Mix.shell().info("")

      Mix.shell().info("Priority Breakdown:")
      Mix.shell().info("  Critical (>=0.8): #{summary.by_priority.critical}")
      Mix.shell().info("  High (>=0.6):     #{summary.by_priority.high}")
      Mix.shell().info("  Medium (>=0.4):   #{summary.by_priority.medium}")
      Mix.shell().info("")

      # Show pattern analysis
      patterns = PatternDiscovery.analyze_wallet_patterns(ref_case)
      display_patterns(patterns)

      # Calculate eligible wallets
      wallets = ref_case.discovered_wallets || []
      eligible = wallets
      |> Enum.filter(fn w -> (w["suspicion_score"] || 0) >= min_score end)
      |> Enum.take(limit)

      Mix.shell().info("")
      Mix.shell().info("With current settings (--min-score #{min_score} --limit #{limit}):")
      Mix.shell().info("  #{length(eligible)} candidate(s) would be created")
      Mix.shell().info("")

      Mix.shell().info("Recommendation: #{summary.recommendation}")
      Mix.shell().info("")
      Mix.shell().info("To promote, run without --dry-run:")
      Mix.shell().info("  mix polymarket.promote --reference-case \"#{ref_case.case_name}\"")
    else
      Mix.shell().info("Cannot promote: #{summary.reason}")
      Mix.shell().info("")
      Mix.shell().info(summary.recommendation)
    end

    Mix.shell().info("")
  end

  defp promote_wallets(ref_case, opts) do
    min_score = opts[:min_score] || 0.4
    limit = opts[:limit] || 20
    priority_override = opts[:priority]

    # Validate priority if provided
    if priority_override && priority_override not in ["critical", "high", "medium", "low"] do
      Mix.shell().error("Invalid --priority value: #{priority_override}")
      Mix.shell().info("Valid values: critical, high, medium, low")
      exit({:shutdown, 1})
    end

    Mix.shell().info("")
    Mix.shell().info("=== Promoting Wallets to Candidates ===")
    Mix.shell().info("")
    Mix.shell().info("Reference Case: #{ref_case.case_name}")
    Mix.shell().info("Min Score: #{min_score}")
    Mix.shell().info("Limit: #{limit}")
    if priority_override, do: Mix.shell().info("Priority Override: #{priority_override}")
    Mix.shell().info("")

    promote_opts = [
      min_score: min_score,
      limit: limit,
      priority_override: priority_override
    ]

    case PatternDiscovery.promote_wallets_to_candidates(ref_case, promote_opts) do
      {:ok, result} ->
        Mix.shell().info("Created #{result.candidates_created} investigation candidate(s)")
        if result.candidates_failed > 0 do
          Mix.shell().info("Failed: #{result.candidates_failed}")
        end
        Mix.shell().info("Batch ID: #{result.batch_id}")
        Mix.shell().info("")

        Mix.shell().info("Next steps:")
        Mix.shell().info("  1. mix polymarket.candidates --batch #{result.batch_id}")
        Mix.shell().info("  2. mix polymarket.candidate --id <ID>")
        Mix.shell().info("  3. mix polymarket.investigate --id <ID>")
        Mix.shell().info("")

      {:error, reason} ->
        Mix.shell().error("Promotion failed: #{reason}")
        Mix.shell().info("")

        # Show helpful context
        summary = PatternDiscovery.promotion_summary(ref_case)
        unless summary.promotable do
          Mix.shell().info(summary.recommendation)
        end
    end
  end

  defp display_patterns(patterns) do
    Mix.shell().info("Pattern Analysis:")

    # Timing patterns
    if map_size(patterns.timing_patterns) > 0 do
      Mix.shell().info("  Timing Distribution:")
      Enum.each(patterns.timing_patterns, fn {timing, count} ->
        label = case timing do
          :immediate -> "Immediate (<24h)"
          :days_before -> "Days before (24-72h)"
          :week_before -> "Week+ before"
          :unknown -> "Unknown timing"
        end
        Mix.shell().info("    #{label}: #{count}")
      end)
    end

    # Volume patterns
    if map_size(patterns.volume_patterns) > 0 do
      Mix.shell().info("  Volume Distribution:")
      Enum.each(patterns.volume_patterns, fn {vol_tier, count} ->
        label = case vol_tier do
          :whale -> "Whale (>$10K)"
          :large -> "Large ($1K-$10K)"
          :medium -> "Medium ($100-$1K)"
          :small -> "Small (<$100)"
        end
        Mix.shell().info("    #{label}: #{count}")
      end)
    end

    Mix.shell().info("  Aggregate Volume: $#{patterns.aggregate_volume}")
    Mix.shell().info("  Avg Suspicion Score: #{patterns.average_suspicion_score}")
    Mix.shell().info("  High Confidence (>=0.6): #{patterns.high_confidence_wallets}")
    Mix.shell().info("  Critical (>=0.8): #{patterns.critical_wallets}")
  end

  defp list_available_cases do
    cases = Repo.all(InsiderReferenceCase)
            |> Enum.filter(&(&1.platform == "polymarket"))
            |> Enum.filter(&(length(&1.discovered_wallets || []) > 0))
            |> Enum.take(10)

    if Enum.empty?(cases) do
      Mix.shell().info("No reference cases with discovered wallets found.")
      Mix.shell().info("")
      Mix.shell().info("Run discovery first:")
      Mix.shell().info("  mix polymarket.discover --reference-case \"Case Name\"")
    else
      Mix.shell().info("Reference cases with discovered wallets:")
      Enum.each(cases, fn c ->
        wallet_count = length(c.discovered_wallets || [])
        has_cid = if c.condition_id, do: "", else: " (no condition_id)"
        Mix.shell().info("  #{c.case_name} (#{wallet_count} wallets)#{has_cid}")
      end)
    end
  end
end
