defmodule Mix.Tasks.Polymarket.Backtest do
  @moduledoc """
  Backtest insider detection algorithm against known reference cases.

  Compares our detected candidates against documented insider trading cases
  to measure detection effectiveness.

  ## Usage

      # Run full backtest against all Polymarket reference cases
      mix polymarket.backtest

      # Verbose mode with detailed matching
      mix polymarket.backtest --verbose

      # Test specific reference case
      mix polymarket.backtest --case "Venezuela/Maduro Raid"

  ## Metrics Calculated

      - Detection Rate: Did we flag activity on markets with known insider trading?
      - Profit Coverage: What % of reported insider profit did we flag?
      - Lead Time: How early did we detect (hours before resolution)?
      - Pattern Match: Did we identify the correct pattern type?

  ## Example Output

      $ mix polymarket.backtest

      ═══════════════════════════════════════════════════════════════
      INSIDER DETECTION BACKTEST
      ═══════════════════════════════════════════════════════════════

      Reference Cases: 4 (Polymarket only)
      Markets Matched: 2
      Detection Rate: 50.0%

      ┌─────────────────────────┬──────────┬────────────┬────────────┬──────────┐
      │ Reference Case          │ Detected │ Ref Profit │ Our Profit │ Coverage │
      ├─────────────────────────┼──────────┼────────────┼────────────┼──────────┤
      │ Venezuela/Maduro Raid   │ ✅       │ $400,000   │ $10,739    │ 2.7%     │
      │ Nobel Peace Prize 2025  │ ❌       │ $10,000    │ $0         │ 0.0%     │
      └─────────────────────────┴──────────┴────────────┴────────────┴──────────┘

  """

  use Mix.Task
  import Ecto.Query
  alias VolfefeMachine.Repo
  alias VolfefeMachine.Polymarket.{InsiderReferenceCase, Market, InvestigationCandidate}

  @shortdoc "Backtest detection against known insider cases"

  # Keywords to match reference cases to markets
  @case_keywords %{
    "Venezuela/Maduro Raid" => ~w(venezuela maduro),
    "Nobel Peace Prize 2025" => ~w(nobel peace prize),
    "Google Year in Search 2025" => ~w(google year search),
    "OpenAI Browser Launch" => ~w(openai browser)
  }

  @impl Mix.Task
  def run(args) do
    Mix.Task.run("app.start")

    {opts, _, _} = OptionParser.parse(args,
      switches: [
        verbose: :boolean,
        case: :string
      ],
      aliases: [v: :verbose, c: :case]
    )

    print_header()

    # Load Polymarket reference cases only
    reference_cases = load_reference_cases(opts[:case])

    if length(reference_cases) == 0 do
      Mix.shell().info("No Polymarket reference cases found.")
      Mix.shell().info("")
      Mix.shell().info("Seed reference cases: mix polymarket.references --seed")
    else
      results = Enum.map(reference_cases, &backtest_case(&1, opts[:verbose] || false))

      print_summary(results)
      print_results_table(results)
      print_detailed_analysis(results, opts[:verbose] || false)
      print_recommendations(results)
    end

    print_footer()
  end

  defp load_reference_cases(nil) do
    from(r in InsiderReferenceCase,
      where: r.platform == "polymarket",
      order_by: [desc: r.event_date]
    )
    |> Repo.all()
  end

  defp load_reference_cases(case_name) do
    from(r in InsiderReferenceCase,
      where: r.platform == "polymarket" and ilike(r.case_name, ^"%#{case_name}%")
    )
    |> Repo.all()
  end

  defp backtest_case(reference_case, verbose) do
    # Find matching markets
    keywords = Map.get(@case_keywords, reference_case.case_name, extract_keywords(reference_case.case_name))
    matched_markets = find_matching_markets(keywords)

    # Get candidates on those markets
    candidates = get_candidates_for_markets(matched_markets)

    # Calculate metrics
    total_flagged_profit = candidates
      |> Enum.map(& &1.estimated_profit)
      |> Enum.reject(&is_nil/1)
      |> Enum.reduce(Decimal.new(0), &Decimal.add/2)

    detected = length(candidates) > 0

    coverage = if reference_case.reported_profit && Decimal.gt?(reference_case.reported_profit, Decimal.new(0)) do
      Decimal.div(total_flagged_profit, reference_case.reported_profit)
      |> Decimal.mult(100)
      |> Decimal.round(1)
      |> Decimal.to_float()
    else
      nil
    end

    # Calculate average lead time
    avg_lead_time = if length(candidates) > 0 do
      candidates
      |> Enum.map(& &1.hours_before_resolution)
      |> Enum.reject(&is_nil/1)
      |> case do
        [] -> nil
        times ->
          sum = Enum.reduce(times, Decimal.new(0), &Decimal.add/2)
          Decimal.div(sum, length(times)) |> Decimal.round(1)
      end
    else
      nil
    end

    if verbose do
      Mix.shell().info("")
      Mix.shell().info("🔍 Matching: #{reference_case.case_name}")
      Mix.shell().info("   Keywords: #{Enum.join(keywords, ", ")}")
      Mix.shell().info("   Markets found: #{length(matched_markets)}")
      Enum.each(matched_markets, fn m ->
        Mix.shell().info("   - [#{m.id}] #{String.slice(m.question, 0, 50)}...")
      end)
      Mix.shell().info("   Candidates: #{length(candidates)}")
    end

    %{
      reference_case: reference_case,
      matched_markets: matched_markets,
      candidates: candidates,
      detected: detected,
      flagged_profit: total_flagged_profit,
      coverage: coverage,
      avg_lead_time: avg_lead_time,
      candidate_count: length(candidates)
    }
  end

  defp extract_keywords(case_name) do
    case_name
    |> String.downcase()
    |> String.replace(~r/[^a-z0-9\s]/, "")
    |> String.split()
    |> Enum.reject(&(String.length(&1) < 4))
    |> Enum.take(3)
  end

  defp find_matching_markets(keywords) do
    # Build dynamic query to match any keyword
    base_query = from(m in Market, where: m.is_active == true or not is_nil(m.resolved_outcome))

    Enum.reduce(keywords, [], fn keyword, acc ->
      matches = from(m in base_query,
        where: ilike(m.question, ^"%#{keyword}%")
      )
      |> Repo.all()

      (acc ++ matches) |> Enum.uniq_by(& &1.id)
    end)
  end

  defp get_candidates_for_markets([]), do: []
  defp get_candidates_for_markets(markets) do
    market_ids = Enum.map(markets, & &1.id)

    from(c in InvestigationCandidate,
      where: c.market_id in ^market_ids,
      order_by: [desc: c.anomaly_score]
    )
    |> Repo.all()
  end

  defp print_header do
    Mix.shell().info("")
    Mix.shell().info(String.duplicate("═", 70))
    Mix.shell().info("INSIDER DETECTION BACKTEST")
    Mix.shell().info(String.duplicate("═", 70))
    Mix.shell().info("")
  end

  defp print_footer do
    Mix.shell().info(String.duplicate("─", 70))
    Mix.shell().info("Reference data: mix polymarket.references")
    Mix.shell().info("Candidate details: mix polymarket.candidates")
    Mix.shell().info("")
  end

  defp print_summary(results) do
    total_cases = length(results)
    detected_count = Enum.count(results, & &1.detected)
    detection_rate = if total_cases > 0, do: Float.round(detected_count / total_cases * 100, 1), else: 0.0

    markets_matched = results
      |> Enum.flat_map(& &1.matched_markets)
      |> Enum.uniq_by(& &1.id)
      |> length()

    total_ref_profit = results
      |> Enum.map(& &1.reference_case.reported_profit)
      |> Enum.reject(&is_nil/1)
      |> Enum.reduce(Decimal.new(0), &Decimal.add/2)

    total_flagged = results
      |> Enum.map(& &1.flagged_profit)
      |> Enum.reduce(Decimal.new(0), &Decimal.add/2)

    overall_coverage = if Decimal.gt?(total_ref_profit, Decimal.new(0)) do
      Decimal.div(total_flagged, total_ref_profit)
      |> Decimal.mult(100)
      |> Decimal.round(1)
      |> Decimal.to_float()
    else
      0.0
    end

    Mix.shell().info("Reference Cases: #{total_cases} (Polymarket only)")
    Mix.shell().info("Markets Matched: #{markets_matched}")
    Mix.shell().info("Detection Rate: #{detection_rate}% (#{detected_count}/#{total_cases})")
    Mix.shell().info("")
    Mix.shell().info("Profit Analysis:")
    Mix.shell().info("├─ Reference Total: #{format_money(total_ref_profit)}")
    Mix.shell().info("├─ Flagged Total: #{format_money(total_flagged)}")
    Mix.shell().info("└─ Overall Coverage: #{overall_coverage}%")
    Mix.shell().info("")
  end

  defp print_results_table(results) do
    Mix.shell().info("┌─────────────────────────┬──────────┬────────────┬────────────┬──────────┐")
    Mix.shell().info("│ Reference Case          │ Detected │ Ref Profit │ Our Profit │ Coverage │")
    Mix.shell().info("├─────────────────────────┼──────────┼────────────┼────────────┼──────────┤")

    Enum.each(results, fn result ->
      name = result.reference_case.case_name
        |> String.slice(0, 21)
        |> String.pad_trailing(23)

      detected = if result.detected, do: "✅      ", else: "❌      "
      ref_profit = format_money_short(result.reference_case.reported_profit) |> String.pad_trailing(10)
      our_profit = format_money_short(result.flagged_profit) |> String.pad_trailing(10)
      coverage = if result.coverage, do: "#{result.coverage}%", else: "N/A"
      coverage = String.pad_trailing(coverage, 8)

      Mix.shell().info("│ #{name} │ #{detected} │ #{ref_profit} │ #{our_profit} │ #{coverage} │")
    end)

    Mix.shell().info("└─────────────────────────┴──────────┴────────────┴────────────┴──────────┘")
    Mix.shell().info("")
  end

  defp print_detailed_analysis(results, true) do
    Mix.shell().info("═══ DETAILED ANALYSIS ═══")
    Mix.shell().info("")

    Enum.each(results, fn result ->
      rc = result.reference_case
      status_icon = if result.detected, do: "✅", else: "❌"

      Mix.shell().info("#{status_icon} #{rc.case_name}")
      Mix.shell().info(String.duplicate("─", 50))
      Mix.shell().info("  Event Date: #{rc.event_date}")
      Mix.shell().info("  Pattern Type: #{rc.pattern_type}")
      Mix.shell().info("  Status: #{rc.status}")
      Mix.shell().info("")
      Mix.shell().info("  Markets Matched: #{length(result.matched_markets)}")

      Enum.each(result.matched_markets, fn market ->
        resolved = if market.resolved_outcome, do: "[#{market.resolved_outcome}]", else: "[pending]"
        Mix.shell().info("    • #{String.slice(market.question, 0, 45)}... #{resolved}")
      end)

      Mix.shell().info("")
      Mix.shell().info("  Candidates Flagged: #{result.candidate_count}")

      if result.detected do
        Mix.shell().info("  Flagged Profit: #{format_money(result.flagged_profit)}")
        Mix.shell().info("  Reference Profit: #{format_money(rc.reported_profit)}")
        Mix.shell().info("  Coverage: #{result.coverage || "N/A"}%")

        if result.avg_lead_time do
          Mix.shell().info("  Avg Lead Time: #{Decimal.to_string(result.avg_lead_time)} hours")
        end
      else
        Mix.shell().info("  ⚠️  No candidates flagged for this case")
        Mix.shell().info("  Possible reasons:")
        Mix.shell().info("    - Market not in our dataset")
        Mix.shell().info("    - Trades occurred outside our data window")
        Mix.shell().info("    - Detection thresholds too high")
      end

      Mix.shell().info("")
    end)
  end

  defp print_detailed_analysis(_results, false), do: :ok

  defp print_recommendations(results) do
    detected = Enum.filter(results, & &1.detected)
    missed = Enum.reject(results, & &1.detected)

    Mix.shell().info("═══ RECOMMENDATIONS ═══")
    Mix.shell().info("")

    if length(detected) > 0 do
      avg_coverage = detected
        |> Enum.map(& &1.coverage)
        |> Enum.reject(&is_nil/1)
        |> case do
          [] -> 0
          coverages -> Enum.sum(coverages) / length(coverages)
        end

      Mix.shell().info("✅ Detection Working: #{length(detected)} cases flagged")

      if avg_coverage < 10 do
        Mix.shell().info("   ⚠️  Low profit coverage (#{Float.round(avg_coverage, 1)}%)")
        Mix.shell().info("   → Consider ingesting more trade data")
        Mix.shell().info("   → The major whales may not be in our dataset")
      end
    end

    if length(missed) > 0 do
      Mix.shell().info("")
      Mix.shell().info("❌ Missed Cases: #{length(missed)}")
      Enum.each(missed, fn result ->
        Mix.shell().info("   • #{result.reference_case.case_name}")
      end)
      Mix.shell().info("")
      Mix.shell().info("   Actions to improve:")
      Mix.shell().info("   → Ingest more markets: mix polymarket.ingest --all-active")
      Mix.shell().info("   → Lower detection thresholds for these categories")
      Mix.shell().info("   → Add specific market monitoring")
    end

    Mix.shell().info("")
  end

  defp format_money(nil), do: "N/A"
  defp format_money(%Decimal{} = d) do
    if Decimal.eq?(d, Decimal.new(0)) do
      "$0"
    else
      "$#{Decimal.round(d, 0) |> Decimal.to_string(:normal)}"
    end
  end

  defp format_money_short(nil), do: "N/A"
  defp format_money_short(%Decimal{} = d) do
    amount = Decimal.to_float(d)
    cond do
      amount >= 1_000_000 -> "$#{Float.round(amount / 1_000_000, 1)}M"
      amount >= 1_000 -> "$#{Float.round(amount / 1_000, 0)}K"
      true -> "$#{round(amount)}"
    end
  end
end
