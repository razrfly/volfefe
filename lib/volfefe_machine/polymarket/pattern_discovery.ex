defmodule VolfefeMachine.Polymarket.PatternDiscovery do
  @moduledoc """
  Pattern discovery and analysis for Polymarket insider detection.

  Bridges reference case discovery (date-range scanning) with investigation
  candidates. Converts discovered wallets into actionable investigation targets.

  ## Workflow

  ```
  Reference Case Discovery      Pattern Discovery           Investigation
  ├─ Scan by date range        ├─ Analyze patterns        ├─ Create candidates
  ├─ Identify markets          ├─ Score wallets           ├─ Track investigation
  └─ Find suspicious wallets   └─ Link to reference       └─ Confirm/dismiss
  ```

  ## Usage

      # Promote discovered wallets to investigation candidates
      {:ok, result} = PatternDiscovery.promote_wallets_to_candidates(ref_case)

      # Analyze patterns in discovered wallets
      patterns = PatternDiscovery.analyze_wallet_patterns(ref_case)

      # Link reference case to market after confirmation
      {:ok, ref_case} = PatternDiscovery.link_reference_to_market(ref_case, condition_id)
  """

  require Logger
  alias VolfefeMachine.Repo
  alias VolfefeMachine.Polymarket.InvestigationCandidate

  @doc """
  Promote discovered wallets from a reference case to investigation candidates.

  Creates investigation candidates for each suspicious wallet found during
  the discovery phase. Links them to the reference case for tracking.

  ## Parameters

  - `ref_case` - InsiderReferenceCase with discovered_wallets
  - `opts` - Options:
    - `:min_score` - Minimum suspicion score (default: 0.4)
    - `:limit` - Maximum candidates to create (default: 20)
    - `:priority_override` - Force a specific priority level

  ## Returns

  - `{:ok, %{candidates_created: n, batch_id: id}}` - Success
  - `{:error, reason}` - Failure
  """
  def promote_wallets_to_candidates(ref_case, opts \\ []) do
    min_score = Keyword.get(opts, :min_score, 0.4)
    limit = Keyword.get(opts, :limit, 20)
    priority_override = Keyword.get(opts, :priority_override)

    wallets = ref_case.discovered_wallets || []

    if Enum.empty?(wallets) do
      {:error, "No discovered wallets to promote. Run discovery first."}
    else
      # Filter by minimum score
      eligible_wallets = wallets
      |> Enum.filter(fn w ->
        score = w["suspicion_score"] || 0
        score >= min_score
      end)
      |> Enum.take(limit)

      if Enum.empty?(eligible_wallets) do
        {:error, "No wallets meet minimum score threshold (#{min_score})"}
      else
        batch_id = generate_batch_id(ref_case)

        # Create candidates
        results = Enum.with_index(eligible_wallets, 1)
        |> Enum.map(fn {wallet, rank} ->
          create_candidate_from_wallet(wallet, ref_case, rank, batch_id, priority_override)
        end)

        successful = Enum.filter(results, &match?({:ok, _}, &1))
        failed = Enum.filter(results, &match?({:error, _}, &1))

        # Update reference case with promotion metadata
        update_promotion_status(ref_case, batch_id, length(successful))

        {:ok, %{
          candidates_created: length(successful),
          candidates_failed: length(failed),
          batch_id: batch_id,
          reference_case: ref_case.case_name
        }}
      end
    end
  end

  @doc """
  Analyze patterns in discovered wallets.

  Groups wallets by behavior patterns and identifies common characteristics.

  ## Returns

  Map with pattern analysis:
  - `:timing_patterns` - Wallets grouped by timing (immediate, day-before, week-before)
  - `:volume_patterns` - Wallets grouped by volume (whale, medium, small)
  - `:cross_market` - Wallets appearing in multiple markets
  """
  def analyze_wallet_patterns(ref_case) do
    wallets = ref_case.discovered_wallets || []
    condition_ids = ref_case.discovered_condition_ids || []

    # Timing patterns
    timing_patterns = group_by_timing(wallets)

    # Volume patterns
    volume_patterns = group_by_volume(wallets)

    # Summary stats
    total_volume = wallets
    |> Enum.map(fn w ->
      case w["total_volume"] do
        nil -> Decimal.new(0)
        vol when is_binary(vol) ->
          case Decimal.parse(vol) do
            {d, _} -> d
            :error -> Decimal.new(0)
          end
        vol -> Decimal.new("#{vol}")
      end
    end)
    |> Enum.reduce(Decimal.new(0), &Decimal.add/2)

    avg_score = if length(wallets) > 0 do
      wallets
      |> Enum.map(fn w -> w["suspicion_score"] || 0 end)
      |> Enum.sum()
      |> Kernel./(length(wallets))
      |> Float.round(4)
    else
      0.0
    end

    %{
      timing_patterns: timing_patterns,
      volume_patterns: volume_patterns,
      total_wallets: length(wallets),
      total_condition_ids: length(condition_ids),
      aggregate_volume: total_volume,
      average_suspicion_score: avg_score,
      high_confidence_wallets: Enum.count(wallets, fn w -> (w["suspicion_score"] || 0) >= 0.6 end),
      critical_wallets: Enum.count(wallets, fn w -> (w["suspicion_score"] || 0) >= 0.8 end)
    }
  end

  @doc """
  Get summary of promotion potential for a reference case.

  Returns counts and recommendations for promoting discovered wallets.
  """
  def promotion_summary(ref_case) do
    wallets = ref_case.discovered_wallets || []

    if Enum.empty?(wallets) do
      %{
        promotable: false,
        reason: "No discovered wallets",
        recommendation: "Run discovery first: mix polymarket.discover --reference-case \"#{ref_case.case_name}\""
      }
    else
      critical = Enum.count(wallets, fn w -> (w["suspicion_score"] || 0) >= 0.8 end)
      high = Enum.count(wallets, fn w ->
        score = w["suspicion_score"] || 0
        score >= 0.6 && score < 0.8
      end)
      medium = Enum.count(wallets, fn w ->
        score = w["suspicion_score"] || 0
        score >= 0.4 && score < 0.6
      end)

      %{
        promotable: true,
        total_wallets: length(wallets),
        by_priority: %{
          critical: critical,
          high: high,
          medium: medium
        },
        recommendation: build_recommendation(critical, high, medium),
        has_condition_id: ref_case.condition_id != nil
      }
    end
  end

  # ============================================
  # Private Functions
  # ============================================

  defp create_candidate_from_wallet(wallet, ref_case, rank, batch_id, priority_override) do
    # Calculate priority from suspicion score
    suspicion_score = wallet["suspicion_score"] || 0.5
    priority = priority_override || calculate_priority_from_suspicion(suspicion_score)

    # Build anomaly breakdown from wallet data
    anomaly_breakdown = %{
      "volume" => %{
        "value" => wallet["total_volume"],
        "severity" => volume_severity(wallet["total_volume"])
      },
      "timing" => %{
        "hours_before" => wallet["hours_before_event"],
        "severity" => timing_severity(wallet["hours_before_event"])
      },
      "whale_trades" => %{
        "count" => wallet["whale_trade_count"] || 0,
        "severity" => whale_severity(wallet["whale_trade_count"] || 0)
      }
    }

    # Build matched patterns from reference case
    matched_patterns = %{
      "reference_case" => %{
        "case_name" => ref_case.case_name,
        "event_date" => ref_case.event_date && Date.to_string(ref_case.event_date),
        "pattern_type" => ref_case.pattern_type
      },
      "discovery_source" => "reference_case_discovery"
    }

    # Parse volume for estimated profit (rough estimate)
    estimated_profit = case wallet["total_volume"] do
      nil -> nil
      vol when is_binary(vol) ->
        case Decimal.parse(vol) do
          {d, _} -> d
          :error -> nil
        end
      vol -> Decimal.new("#{vol}")
    end

    attrs = %{
      wallet_address: wallet["address"],
      condition_id: ref_case.condition_id,
      discovery_rank: rank,
      anomaly_score: Decimal.from_float(suspicion_score),
      insider_probability: Decimal.from_float(suspicion_score),
      market_question: ref_case.market_question,
      trade_size: estimated_profit,
      estimated_profit: estimated_profit,
      hours_before_resolution: wallet["hours_before_event"],
      anomaly_breakdown: anomaly_breakdown,
      matched_patterns: matched_patterns,
      status: "undiscovered",
      priority: priority,
      batch_id: batch_id,
      discovered_at: DateTime.utc_now()
    }

    %InvestigationCandidate{}
    |> InvestigationCandidate.changeset(attrs)
    |> Repo.insert()
  end

  defp calculate_priority_from_suspicion(score) when score >= 0.8, do: "critical"
  defp calculate_priority_from_suspicion(score) when score >= 0.6, do: "high"
  defp calculate_priority_from_suspicion(score) when score >= 0.4, do: "medium"
  defp calculate_priority_from_suspicion(_), do: "low"

  defp volume_severity(nil), do: "unknown"
  defp volume_severity(vol) when is_binary(vol) do
    case Decimal.parse(vol) do
      {d, _} -> volume_severity_decimal(d)
      :error -> "unknown"
    end
  end
  defp volume_severity(vol), do: volume_severity_decimal(Decimal.new("#{vol}"))

  defp volume_severity_decimal(d) do
    cond do
      Decimal.compare(d, Decimal.new(10000)) == :gt -> "extreme"
      Decimal.compare(d, Decimal.new(5000)) == :gt -> "very_high"
      Decimal.compare(d, Decimal.new(1000)) == :gt -> "high"
      Decimal.compare(d, Decimal.new(500)) == :gt -> "elevated"
      true -> "normal"
    end
  end

  defp timing_severity(nil), do: "unknown"
  defp timing_severity(hours) when hours <= 24, do: "extreme"
  defp timing_severity(hours) when hours <= 48, do: "very_high"
  defp timing_severity(hours) when hours <= 72, do: "high"
  defp timing_severity(hours) when hours <= 168, do: "elevated"
  defp timing_severity(_), do: "normal"

  defp whale_severity(count) when count >= 5, do: "extreme"
  defp whale_severity(count) when count >= 3, do: "very_high"
  defp whale_severity(count) when count >= 2, do: "high"
  defp whale_severity(count) when count >= 1, do: "elevated"
  defp whale_severity(_), do: "normal"

  defp generate_batch_id(ref_case) do
    timestamp = DateTime.utc_now() |> DateTime.to_unix()
    slug = ref_case.case_name
    |> String.downcase()
    |> String.replace(~r/[^a-z0-9]+/, "-")
    |> String.slice(0, 20)

    "refcase-#{slug}-#{timestamp}"
  end

  defp update_promotion_status(ref_case, batch_id, count) do
    notes = (ref_case.analysis_notes || "") <>
      "\n\nPromotion: #{DateTime.utc_now()}\n" <>
      "Batch: #{batch_id}\n" <>
      "Candidates created: #{count}"

    ref_case
    |> Ecto.Changeset.change(%{analysis_notes: notes})
    |> Repo.update()
  end

  defp group_by_timing(wallets) do
    wallets
    |> Enum.group_by(fn w ->
      case w["hours_before_event"] do
        nil -> :unknown
        h when h <= 24 -> :immediate
        h when h <= 72 -> :days_before
        _ -> :week_before
      end
    end)
    |> Enum.map(fn {k, v} -> {k, length(v)} end)
    |> Map.new()
  end

  defp group_by_volume(wallets) do
    wallets
    |> Enum.group_by(fn w ->
      vol = case w["total_volume"] do
        nil -> 0
        v when is_binary(v) ->
          case Float.parse(v) do
            {f, _} -> f
            :error -> 0
          end
        v -> v
      end

      cond do
        vol >= 10000 -> :whale
        vol >= 1000 -> :large
        vol >= 100 -> :medium
        true -> :small
      end
    end)
    |> Enum.map(fn {k, v} -> {k, length(v)} end)
    |> Map.new()
  end

  defp build_recommendation(critical, high, medium) do
    cond do
      critical > 0 ->
        "#{critical} critical wallet(s) found! Immediate investigation recommended."
      high > 0 ->
        "#{high} high-priority wallet(s) found. Promote for investigation."
      medium > 0 ->
        "#{medium} medium-priority wallet(s) found. Review before promoting."
      true ->
        "No high-priority wallets. Consider lowering threshold or expanding discovery window."
    end
  end
end
