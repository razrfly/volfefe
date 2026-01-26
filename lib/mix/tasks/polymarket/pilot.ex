defmodule Mix.Tasks.Polymarket.Pilot do
  @moduledoc """
  Phase 1 Pilot Validation for insider detection system.

  Validates detection algorithm against confirmed insiders, identifies
  pattern gaps, and discovers high-volume markets for pilot testing.

  ## Usage

      # Run full pilot validation
      mix polymarket.pilot

      # Validate detection with verbose output
      mix polymarket.pilot --validate --verbose

      # Analyze false negatives
      mix polymarket.pilot --analyze-misses

      # Find high-volume markets for pilot
      mix polymarket.pilot --markets

      # Run threshold optimization
      mix polymarket.pilot --optimize

      # Full pilot workflow
      mix polymarket.pilot --full

      # Run batch discovery on pilot markets
      mix polymarket.pilot --batch --limit 10

      # Check pilot progress
      mix polymarket.pilot --progress

      # Export results for review
      mix polymarket.pilot --export

  ## Validation Metrics

      - Detection Rate: % of confirmed insiders we flagged
      - Precision: Of flagged candidates, how many are real?
      - Recall: Of real insiders, how many did we flag?
      - F1 Score: Harmonic mean of precision and recall

  ## Example Output

      $ mix polymarket.pilot --validate

      ═══════════════════════════════════════════════════════════════
      PHASE 1: PILOT VALIDATION
      ═══════════════════════════════════════════════════════════════

      Confirmed Insiders: 50
      Detected: 42 (84.0%)
      Missed: 8 (16.0%)

      ┌────────────────┬───────┬──────────┬────────┬──────────────┐
      │ Category       │ Total │ Detected │ Missed │ Rate         │
      ├────────────────┼───────┼──────────┼────────┼──────────────┤
      │ politics       │ 23    │ 20       │ 3      │ 87.0%        │
      │ crypto         │ 8     │ 6        │ 2      │ 75.0%        │
      └────────────────┴───────┴──────────┴────────┴──────────────┘

      Metrics:
      ├─ Precision: 0.89
      ├─ Recall: 0.84
      └─ F1 Score: 0.86

  """

  use Mix.Task
  alias VolfefeMachine.Polymarket.Validation

  @shortdoc "Run pilot validation against confirmed insiders"

  @impl Mix.Task
  def run(args) do
    Mix.Task.run("app.start")

    {opts, _, _} = OptionParser.parse(args,
      switches: [
        validate: :boolean,
        analyze_misses: :boolean,
        markets: :boolean,
        optimize: :boolean,
        coverage: :boolean,
        full: :boolean,
        batch: :boolean,
        progress: :boolean,
        export: :boolean,
        verbose: :boolean,
        limit: :integer,
        anomaly_threshold: :float,
        probability_threshold: :float
      ],
      aliases: [
        v: :verbose,
        a: :analyze_misses,
        m: :markets,
        o: :optimize,
        f: :full,
        b: :batch,
        p: :progress,
        e: :export
      ]
    )

    cond do
      opts[:full] ->
        run_full_pilot(opts)

      opts[:validate] ->
        run_validation(opts)

      opts[:analyze_misses] ->
        run_miss_analysis(opts)

      opts[:markets] ->
        run_market_discovery(opts)

      opts[:optimize] ->
        run_threshold_optimization(opts)

      opts[:coverage] ->
        run_coverage_analysis(opts)

      opts[:batch] ->
        run_batch_processing(opts)

      opts[:progress] ->
        run_progress_check(opts)

      opts[:export] ->
        run_export(opts)

      true ->
        # Default: show summary
        run_summary(opts)
    end
  end

  # ============================================
  # Command Handlers
  # ============================================

  defp run_full_pilot(opts) do
    print_header("PHASE 1: FULL PILOT VALIDATION")

    Mix.shell().info("Running comprehensive pilot validation workflow...")
    Mix.shell().info("")

    # Step 1: Validation
    Mix.shell().info("━━━ Step 1: Detection Validation ━━━")
    run_validation(opts)
    Mix.shell().info("")

    # Step 2: False Negative Analysis
    Mix.shell().info("━━━ Step 2: False Negative Analysis ━━━")
    run_miss_analysis(opts)
    Mix.shell().info("")

    # Step 3: Category Coverage
    Mix.shell().info("━━━ Step 3: Category Coverage ━━━")
    run_coverage_analysis(opts)
    Mix.shell().info("")

    # Step 4: Market Discovery
    Mix.shell().info("━━━ Step 4: High-Volume Markets for Pilot ━━━")
    run_market_discovery(Keyword.put(opts, :limit, 20))
    Mix.shell().info("")

    # Step 5: Threshold Optimization
    Mix.shell().info("━━━ Step 5: Threshold Optimization ━━━")
    run_threshold_optimization(opts)

    print_footer()
    print_next_steps()
  end

  defp run_validation(opts) do
    print_header("DETECTION VALIDATION")

    validation_opts = [
      anomaly_threshold: opts[:anomaly_threshold] || 0.5,
      probability_threshold: opts[:probability_threshold] || 0.4
    ]

    case Validation.validate_detection(validation_opts) do
      {:ok, results} ->
        print_validation_summary(results)
        print_category_breakdown(results.by_category)
        print_confidence_breakdown(results.by_confidence)

        if opts[:verbose] do
          print_false_negative_details(results.false_negatives)
        end

        # Also get precision/recall/F1
        case Validation.calculate_metrics(validation_opts) do
          {:ok, metrics} ->
            print_metrics(metrics)
          _ ->
            :ok
        end
    end

    print_footer()
  end

  defp run_miss_analysis(opts) do
    print_header("FALSE NEGATIVE ANALYSIS")

    validation_opts = [
      anomaly_threshold: opts[:anomaly_threshold] || 0.5,
      probability_threshold: opts[:probability_threshold] || 0.4
    ]

    case Validation.analyze_false_negatives(validation_opts) do
      {:ok, analysis} ->
        print_miss_analysis(analysis, opts[:verbose] || false)
    end

    print_footer()
  end

  defp run_market_discovery(opts) do
    print_header("HIGH-VOLUME PILOT MARKETS")

    limit = opts[:limit] || 50

    markets = Validation.find_pilot_markets(limit: limit)

    if Enum.empty?(markets) do
      Mix.shell().info("No resolved markets found. Run: mix polymarket.sync --full")
    else
      print_pilot_markets(markets, opts[:verbose] || false)
    end

    print_footer()
  end

  defp run_threshold_optimization(_opts) do
    print_header("THRESHOLD OPTIMIZATION")

    case Validation.optimize_thresholds() do
      {:ok, results} ->
        print_optimization_results(results)
    end

    print_footer()
  end

  defp run_coverage_analysis(_opts) do
    print_header("CATEGORY COVERAGE")

    coverage = Validation.category_coverage()
    print_coverage(coverage)

    print_footer()
  end

  defp run_batch_processing(opts) do
    print_header("BATCH PILOT PROCESSING")

    limit = opts[:limit] || 10

    Mix.shell().info("Processing #{limit} high-volume pilot markets...")
    Mix.shell().info("")

    batch_opts = [
      limit: limit,
      anomaly_threshold: opts[:anomaly_threshold] || 0.5,
      probability_threshold: opts[:probability_threshold] || 0.4
    ]

    case Validation.run_batch_pilot(batch_opts) do
      {:ok, results} ->
        print_batch_results(results)
    end

    print_footer()
  end

  defp run_progress_check(_opts) do
    print_header("PILOT PROGRESS REPORT")

    progress = Validation.pilot_progress()
    print_progress(progress)

    print_footer()
  end

  defp run_summary(opts) do
    print_header("PILOT VALIDATION SUMMARY")

    # Quick validation
    validation_opts = [
      anomaly_threshold: opts[:anomaly_threshold] || 0.5,
      probability_threshold: opts[:probability_threshold] || 0.4
    ]

    case Validation.validate_detection(validation_opts) do
      {:ok, results} ->
        Mix.shell().info("Confirmed Insiders: #{results.total_insiders}")
        Mix.shell().info("Detected: #{results.detected} (#{format_percent(results.detection_rate)})")
        Mix.shell().info("Missed: #{results.missed}")
        Mix.shell().info("")

        case Validation.calculate_metrics(validation_opts) do
          {:ok, metrics} ->
            Mix.shell().info("Quick Metrics:")
            Mix.shell().info("├─ Precision: #{Float.round(metrics.precision, 2)}")
            Mix.shell().info("├─ Recall: #{Float.round(metrics.recall, 2)}")
            Mix.shell().info("└─ F1 Score: #{Float.round(metrics.f1_score, 2)}")

          _ ->
            :ok
        end
    end

    Mix.shell().info("")
    Mix.shell().info("Available commands:")
    Mix.shell().info("  mix polymarket.pilot --validate        Full validation details")
    Mix.shell().info("  mix polymarket.pilot --analyze-misses  Analyze false negatives")
    Mix.shell().info("  mix polymarket.pilot --markets         Find pilot markets")
    Mix.shell().info("  mix polymarket.pilot --optimize        Threshold optimization")
    Mix.shell().info("  mix polymarket.pilot --coverage        Category coverage")
    Mix.shell().info("  mix polymarket.pilot --full            Run complete workflow")

    print_footer()
  end

  defp run_export(opts) do
    print_header("EXPORTING PILOT RESULTS")

    timestamp = DateTime.utc_now() |> Calendar.strftime("%Y%m%d_%H%M%S")
    base_path = "priv/pilot_results"
    File.mkdir_p!(base_path)

    # Export validation results
    validation_opts = [
      anomaly_threshold: opts[:anomaly_threshold] || 0.5,
      probability_threshold: opts[:probability_threshold] || 0.4
    ]

    case Validation.validate_detection(validation_opts) do
      {:ok, results} ->
        validation_file = Path.join(base_path, "validation_#{timestamp}.json")
        json = Jason.encode!(results, pretty: true)
        File.write!(validation_file, json)
        Mix.shell().info("✅ Validation results: #{validation_file}")

      _ ->
        Mix.shell().error("Failed to export validation results")
    end

    # Export false negative analysis
    case Validation.analyze_false_negatives(validation_opts) do
      {:ok, analysis} ->
        # Strip non-serializable data
        clean_analysis = %{
          total_missed: analysis.total_missed,
          reasons: analysis.reasons,
          metric_gaps: analysis.metric_gaps,
          recommendations: analysis.recommendations
        }
        analysis_file = Path.join(base_path, "false_negatives_#{timestamp}.json")
        json = Jason.encode!(clean_analysis, pretty: true)
        File.write!(analysis_file, json)
        Mix.shell().info("✅ False negative analysis: #{analysis_file}")

      _ ->
        :ok
    end

    # Export pilot markets
    markets = Validation.find_pilot_markets(limit: 100)
    market_data = Enum.map(markets, fn m ->
      %{
        condition_id: m.market.condition_id,
        question: m.market.question,
        category: m.market.category,
        volume: Decimal.to_string(m.market.volume || Decimal.new(0)),
        resolved_outcome: m.market.resolved_outcome,
        trade_count: m.trade_count,
        candidate_count: m.candidate_count,
        has_insider_data: m.has_insider_data,
        priority_score: Float.round(m.score, 2)
      }
    end)
    markets_file = Path.join(base_path, "pilot_markets_#{timestamp}.json")
    File.write!(markets_file, Jason.encode!(market_data, pretty: true))
    Mix.shell().info("✅ Pilot markets: #{markets_file}")

    # Export threshold optimization
    case Validation.optimize_thresholds() do
      {:ok, thresholds} ->
        thresh_file = Path.join(base_path, "thresholds_#{timestamp}.json")
        File.write!(thresh_file, Jason.encode!(thresholds, pretty: true))
        Mix.shell().info("✅ Threshold optimization: #{thresh_file}")

      _ ->
        :ok
    end

    Mix.shell().info("")
    Mix.shell().info("All exports saved to: #{base_path}/")

    print_footer()
  end

  # ============================================
  # Print Functions
  # ============================================

  defp print_header(title) do
    Mix.shell().info("")
    Mix.shell().info(String.duplicate("═", 70))
    Mix.shell().info(title)
    Mix.shell().info(String.duplicate("═", 70))
    Mix.shell().info("")
  end

  defp print_footer do
    Mix.shell().info(String.duplicate("─", 70))
  end

  defp print_validation_summary(results) do
    Mix.shell().info("Confirmed Insiders: #{results.total_insiders}")
    Mix.shell().info("Detected: #{results.detected} (#{format_percent(results.detection_rate)})")
    Mix.shell().info("Missed: #{results.missed} (#{format_percent(1 - results.detection_rate)})")
    Mix.shell().info("")
    Mix.shell().info("Thresholds Used:")
    Mix.shell().info("├─ Anomaly: #{results.thresholds.anomaly}")
    Mix.shell().info("└─ Probability: #{results.thresholds.probability}")
    Mix.shell().info("")
  end

  defp print_category_breakdown(by_category) when map_size(by_category) == 0 do
    Mix.shell().info("No category breakdown available")
  end

  defp print_category_breakdown(by_category) do
    Mix.shell().info("By Category:")
    Mix.shell().info("┌────────────────┬───────┬──────────┬────────┬──────────────┐")
    Mix.shell().info("│ Category       │ Total │ Detected │ Missed │ Rate         │")
    Mix.shell().info("├────────────────┼───────┼──────────┼────────┼──────────────┤")

    by_category
    |> Enum.sort_by(fn {_, stats} -> -stats.total end)
    |> Enum.each(fn {category, stats} ->
      cat = String.pad_trailing(to_string(category), 14)
      total = String.pad_trailing("#{stats.total}", 5)
      detected = String.pad_trailing("#{stats.detected}", 8)
      missed = String.pad_trailing("#{stats.missed}", 6)
      rate = String.pad_trailing(format_percent(stats.detection_rate), 12)

      Mix.shell().info("│ #{cat} │ #{total} │ #{detected} │ #{missed} │ #{rate} │")
    end)

    Mix.shell().info("└────────────────┴───────┴──────────┴────────┴──────────────┘")
    Mix.shell().info("")
  end

  defp print_confidence_breakdown(by_confidence) when map_size(by_confidence) == 0 do
    :ok
  end

  defp print_confidence_breakdown(by_confidence) do
    Mix.shell().info("By Confidence Level:")
    Mix.shell().info("┌────────────────┬───────┬──────────┬────────┬──────────────┐")
    Mix.shell().info("│ Confidence     │ Total │ Detected │ Missed │ Rate         │")
    Mix.shell().info("├────────────────┼───────┼──────────┼────────┼──────────────┤")

    by_confidence
    |> Enum.sort_by(fn {level, _} ->
      case level do
        "confirmed" -> 0
        "likely" -> 1
        "suspected" -> 2
        _ -> 3
      end
    end)
    |> Enum.each(fn {level, stats} ->
      lvl = String.pad_trailing(to_string(level), 14)
      total = String.pad_trailing("#{stats.total}", 5)
      detected = String.pad_trailing("#{stats.detected}", 8)
      missed = String.pad_trailing("#{stats.missed}", 6)
      rate = String.pad_trailing(format_percent(stats.detection_rate), 12)

      Mix.shell().info("│ #{lvl} │ #{total} │ #{detected} │ #{missed} │ #{rate} │")
    end)

    Mix.shell().info("└────────────────┴───────┴──────────┴────────┴──────────────┘")
    Mix.shell().info("")
  end

  defp print_metrics(metrics) do
    Mix.shell().info("Detection Metrics:")
    Mix.shell().info("├─ True Positives: #{metrics.true_positives}")
    Mix.shell().info("├─ False Positives: #{metrics.false_positives}")
    Mix.shell().info("├─ False Negatives: #{metrics.false_negatives}")
    Mix.shell().info("├─ Precision: #{Float.round(metrics.precision, 4)}")
    Mix.shell().info("├─ Recall: #{Float.round(metrics.recall, 4)}")
    Mix.shell().info("└─ F1 Score: #{Float.round(metrics.f1_score, 4)}")
    Mix.shell().info("")
  end

  defp print_false_negative_details([]) do
    Mix.shell().info("✅ No false negatives!")
  end

  defp print_false_negative_details(false_negatives) do
    Mix.shell().info("")
    Mix.shell().info("═══ FALSE NEGATIVE DETAILS ═══")
    Mix.shell().info("")

    Enum.each(false_negatives, fn fn_item ->
      insider = fn_item.insider
      Mix.shell().info("❌ #{insider.wallet_address}")
      Mix.shell().info("   Condition: #{insider.condition_id || "N/A"}")
      Mix.shell().info("   Confidence: #{insider.confidence_level}")
      Mix.shell().info("   Source: #{insider.confirmation_source}")
      Mix.shell().info("   Reason: #{fn_item.reason}")

      if fn_item.score do
        Mix.shell().info("   Anomaly Score: #{fn_item.score.anomaly_score}")
        Mix.shell().info("   Insider Prob: #{fn_item.score.insider_probability}")
      end

      Mix.shell().info("")
    end)
  end

  defp print_miss_analysis(analysis, verbose) do
    Mix.shell().info("Total Missed: #{analysis.total_missed}")
    Mix.shell().info("")

    Mix.shell().info("Reasons:")
    Enum.each(analysis.reasons, fn {reason, count} ->
      if count > 0 do
        icon = case reason do
          :no_trade_data -> "📦"
          :trade_not_scored -> "📊"
          :low_anomaly_score -> "📉"
          :low_probability -> "🎯"
          _ -> "•"
        end
        Mix.shell().info("  #{icon} #{humanize_reason(reason)}: #{count}")
      end
    end)
    Mix.shell().info("")

    if map_size(analysis.metric_gaps) > 0 do
      Mix.shell().info("Metric Gaps (frequently low Z-scores):")
      analysis.metric_gaps
      |> Enum.sort_by(fn {_, count} -> -count end)
      |> Enum.each(fn {metric, count} ->
        Mix.shell().info("  • #{metric}: #{count} insiders")
      end)
      Mix.shell().info("")
    end

    if length(analysis.recommendations) > 0 do
      Mix.shell().info("Recommendations:")
      Enum.each(analysis.recommendations, fn rec ->
        Mix.shell().info("  💡 #{rec}")
      end)
      Mix.shell().info("")
    end

    if verbose do
      Mix.shell().info("═══ DETAILED BREAKDOWN ═══")
      Enum.each(analysis.details, fn detail ->
        Mix.shell().info("")
        Mix.shell().info("• #{detail.insider.wallet_address}")
        Mix.shell().info("  #{detail.reason}")
      end)
    end
  end

  defp print_pilot_markets(markets, verbose) do
    Mix.shell().info("Found #{length(markets)} high-volume resolved markets")
    Mix.shell().info("")

    # Show top markets
    top_markets = if verbose, do: markets, else: Enum.take(markets, 20)

    Mix.shell().info("┌────────────────────────────────────────────┬────────────┬────────┬──────────┐")
    Mix.shell().info("│ Market Question                            │ Volume     │ Trades │ Priority │")
    Mix.shell().info("├────────────────────────────────────────────┼────────────┼────────┼──────────┤")

    Enum.each(top_markets, fn m ->
      question = m.market.question
        |> String.slice(0, 40)
        |> String.pad_trailing(42)

      volume = format_volume(m.market.volume) |> String.pad_trailing(10)
      trades = String.pad_trailing("#{m.trade_count}", 6)
      priority = String.pad_trailing(Float.round(m.score, 1) |> to_string(), 8)

      insider_marker = if m.has_insider_data, do: "🔴", else: "  "

      Mix.shell().info("│ #{question} │ #{volume} │ #{trades} │ #{priority} │#{insider_marker}")
    end)

    Mix.shell().info("└────────────────────────────────────────────┴────────────┴────────┴──────────┘")

    if not verbose and length(markets) > 20 do
      Mix.shell().info("")
      Mix.shell().info("  (showing top 20, use --verbose for all #{length(markets)})")
    end

    Mix.shell().info("")
    Mix.shell().info("🔴 = Has confirmed insider data (good for validation)")
    Mix.shell().info("")
    Mix.shell().info("Next step: mix polymarket.discover --market CONDITION_ID")
  end

  defp print_optimization_results(results) when length(results) == 0 do
    Mix.shell().info("No optimization results. Need confirmed insiders for testing.")
  end

  defp print_optimization_results(results) do
    Mix.shell().info("Threshold Combinations (sorted by F1 score):")
    Mix.shell().info("")
    Mix.shell().info("┌─────────┬─────────┬───────────┬────────┬────────┐")
    Mix.shell().info("│ Anomaly │ Prob    │ Precision │ Recall │ F1     │")
    Mix.shell().info("├─────────┼─────────┼───────────┼────────┼────────┤")

    # Show top 10 results
    results
    |> Enum.take(10)
    |> Enum.with_index()
    |> Enum.each(fn {r, idx} ->
      marker = if idx == 0, do: "★", else: " "
      anomaly = String.pad_trailing("#{r.anomaly_threshold}", 7)
      prob = String.pad_trailing("#{r.probability_threshold}", 7)
      precision = String.pad_trailing("#{Float.round(r.precision, 3)}", 9)
      recall = String.pad_trailing("#{Float.round(r.recall, 3)}", 6)
      f1 = String.pad_trailing("#{Float.round(r.f1_score, 3)}", 6)

      Mix.shell().info("│ #{anomaly} │ #{prob} │ #{precision} │ #{recall} │ #{f1} │#{marker}")
    end)

    Mix.shell().info("└─────────┴─────────┴───────────┴────────┴────────┘")
    Mix.shell().info("")

    best = List.first(results)
    Mix.shell().info("★ Recommended: anomaly=#{best.anomaly_threshold}, probability=#{best.probability_threshold}")
    Mix.shell().info("  → F1=#{Float.round(best.f1_score, 3)}, Precision=#{Float.round(best.precision, 3)}, Recall=#{Float.round(best.recall, 3)}")
  end

  defp print_coverage(coverage) do
    Mix.shell().info("Total Confirmed Insiders: #{coverage.total_insiders}")
    Mix.shell().info("Total Trades: #{format_number(coverage.total_trades)}")
    Mix.shell().info("Total Candidates: #{format_number(coverage.total_candidates)}")
    Mix.shell().info("")

    Mix.shell().info("┌────────────────┬──────────┬────────────┬────────────┐")
    Mix.shell().info("│ Category       │ Insiders │ Trades     │ Candidates │")
    Mix.shell().info("├────────────────┼──────────┼────────────┼────────────┤")

    coverage.by_category
    |> Enum.sort_by(fn {_, stats} -> -stats.insiders end)
    |> Enum.each(fn {category, stats} ->
      cat = String.pad_trailing(to_string(category), 14)
      insiders = String.pad_trailing("#{stats.insiders}", 8)
      trades = String.pad_trailing(format_number(stats.trades), 10)
      candidates = String.pad_trailing("#{stats.candidates}", 10)

      # Highlight categories with few insiders
      warning = if stats.insiders < 5 and stats.trades > 1000, do: "⚠️", else: "  "

      Mix.shell().info("│ #{cat} │ #{insiders} │ #{trades} │ #{candidates} │#{warning}")
    end)

    Mix.shell().info("└────────────────┴──────────┴────────────┴────────────┘")
    Mix.shell().info("")
    Mix.shell().info("⚠️ = Low insider count relative to trades (potential gap)")
  end

  defp print_batch_results(results) do
    Mix.shell().info("Batch Processing Complete")
    Mix.shell().info("")
    Mix.shell().info("Summary:")
    Mix.shell().info("├─ Markets Processed: #{results.markets_processed}")
    Mix.shell().info("├─ Trades Ingested: #{format_number(results.trades_ingested)}")
    Mix.shell().info("├─ Candidates Generated: #{results.candidates_generated}")
    Mix.shell().info("└─ Errors: #{results.errors}")
    Mix.shell().info("")

    if length(results.markets) > 0 do
      Mix.shell().info("Market Details:")
      Mix.shell().info("┌────────────────────────────────────────┬──────────┬────────────┐")
      Mix.shell().info("│ Market                                 │ Trades   │ Candidates │")
      Mix.shell().info("├────────────────────────────────────────┼──────────┼────────────┤")

      Enum.each(results.markets, fn m ->
        question = m.market.question
          |> String.slice(0, 36)
          |> String.pad_trailing(38)

        trades = String.pad_trailing("#{m.trades_ingested}", 8)
        candidates = String.pad_trailing("#{m.candidates_generated}", 10)

        status = if m.error, do: "❌", else: "✅"

        Mix.shell().info("│ #{question} │ #{trades} │ #{candidates} │#{status}")
      end)

      Mix.shell().info("└────────────────────────────────────────┴──────────┴────────────┘")
    end

    Mix.shell().info("")
    Mix.shell().info("Next: Review candidates with mix polymarket.candidates")
  end

  defp print_progress(progress) do
    # Status indicator
    status_icon = case progress.status do
      :ready_for_production -> "🟢"
      :pilot_in_progress -> "🟡"
      :metrics_below_target -> "🟡"
      :detection_poor -> "🟠"
      :need_more_insiders -> "🔴"
      _ -> "⚪"
    end

    status_text = case progress.status do
      :ready_for_production -> "Ready for Production"
      :pilot_in_progress -> "Pilot In Progress"
      :metrics_below_target -> "Metrics Below Target"
      :detection_poor -> "Detection Needs Work"
      :need_more_insiders -> "Need More Training Data"
      _ -> "Unknown"
    end

    Mix.shell().info("Status: #{status_icon} #{status_text}")
    Mix.shell().info("")

    # Validation stats
    Mix.shell().info("Detection Validation:")
    Mix.shell().info("├─ Confirmed Insiders: #{progress.validation.insiders_total}")
    Mix.shell().info("├─ Detected: #{progress.validation.insiders_detected}")
    Mix.shell().info("└─ Detection Rate: #{format_percent(progress.validation.detection_rate)}")
    Mix.shell().info("")

    # Metrics
    Mix.shell().info("Quality Metrics:")
    Mix.shell().info("├─ Precision: #{Float.round(progress.metrics.precision, 3)}")
    Mix.shell().info("├─ Recall: #{Float.round(progress.metrics.recall, 3)}")
    Mix.shell().info("└─ F1 Score: #{Float.round(progress.metrics.f1_score, 3)}")
    Mix.shell().info("")

    # Pilot markets
    Mix.shell().info("Pilot Markets:")
    Mix.shell().info("├─ Total: #{progress.pilot_markets.total}")
    Mix.shell().info("├─ With Trade Data: #{progress.pilot_markets.with_trade_data}")
    Mix.shell().info("├─ With Candidates: #{progress.pilot_markets.with_candidates}")
    Mix.shell().info("└─ Pending Ingestion: #{progress.pilot_markets.pending}")
    Mix.shell().info("")

    # Training data
    Mix.shell().info("Training Data:")
    Mix.shell().info("├─ Total Insiders: #{progress.coverage.total_insiders}")
    Mix.shell().info("├─ Total Trades: #{format_number(progress.coverage.total_trades)}")
    Mix.shell().info("└─ Total Candidates: #{format_number(progress.coverage.total_candidates)}")
    Mix.shell().info("")

    # Recommended actions
    if length(progress.next_actions) > 0 do
      Mix.shell().info("Recommended Actions:")
      Enum.each(progress.next_actions, fn action ->
        Mix.shell().info("  → #{action}")
      end)
    end
  end

  defp print_next_steps do
    Mix.shell().info("")
    Mix.shell().info("═══ NEXT STEPS ═══")
    Mix.shell().info("")
    Mix.shell().info("1. Review false negatives and adjust detection thresholds")
    Mix.shell().info("2. Ingest more trades: mix polymarket.ingest --days 30")
    Mix.shell().info("3. Run discovery on pilot markets: mix polymarket.discover --market CONDITION_ID")
    Mix.shell().info("4. Review candidates: mix polymarket.candidates --priority high")
    Mix.shell().info("5. Confirm new insiders: mix polymarket.confirm CANDIDATE_ID")
    Mix.shell().info("")
  end

  # ============================================
  # Helpers
  # ============================================

  defp format_percent(rate) when is_float(rate) do
    "#{Float.round(rate * 100, 1)}%"
  end

  defp format_percent(_), do: "N/A"

  defp format_volume(nil), do: "$0"
  defp format_volume(%Decimal{} = d) do
    amount = Decimal.to_float(d)
    cond do
      amount >= 1_000_000 -> "$#{Float.round(amount / 1_000_000, 1)}M"
      amount >= 1_000 -> "$#{Float.round(amount / 1_000, 0)}K"
      true -> "$#{round(amount)}"
    end
  end

  defp format_number(n) when is_integer(n) do
    cond do
      n >= 1_000_000 -> "#{Float.round(n / 1_000_000, 1)}M"
      n >= 1_000 -> "#{Float.round(n / 1_000, 0)}K"
      true -> "#{n}"
    end
  end

  defp format_number(_), do: "0"

  defp humanize_reason(:no_trade_data), do: "No trade data in system"
  defp humanize_reason(:trade_not_scored), do: "Trade not scored"
  defp humanize_reason(:low_anomaly_score), do: "Low anomaly score"
  defp humanize_reason(:low_probability), do: "Low probability score"
  defp humanize_reason(reason), do: to_string(reason)
end
