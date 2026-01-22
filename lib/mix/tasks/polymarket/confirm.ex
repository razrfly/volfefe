defmodule Mix.Tasks.Polymarket.Confirm do
  @moduledoc """
  Confirm candidates as insiders or confirm market matches for reference cases.

  ## Mode 1: Confirm Candidate as Insider

  Shortcut for `mix polymarket.resolve --id ID --resolution confirmed_insider`.

      # Confirm candidate as insider
      mix polymarket.confirm --id 1

      # With notes
      mix polymarket.confirm --id 1 --notes "Timing analysis confirms pre-knowledge"

  ## Mode 2: Confirm Reference Case Market Match

  After running `mix polymarket.discover --reference-case`, use this to confirm
  which market matches the reference case:

      # Confirm market match for reference case
      mix polymarket.confirm --reference-case "Nobel Peace Prize 2025" --condition 0x14a3...

      # With market metadata (auto-fetched if omitted)
      mix polymarket.confirm --reference-case "Case Name" --condition 0xabc... --slug "market-slug"

  ## Options

      # Candidate confirmation
      --id          Candidate ID
      --notes       Investigation notes
      --evidence    Evidence URL or reference
      --confidence  Confidence level: confirmed (default) or likely
      --confirmed-by Who confirmed it (default: "cli")

      # Reference case confirmation
      --reference-case  Reference case name
      --condition       Condition ID from discover output
      --slug            Market slug (optional, auto-fetched)
      --question        Market question (optional, auto-fetched)

  ## Workflow

  ### Candidate Investigation Workflow

      1. mix polymarket.candidates           # Find suspicious candidates
      2. mix polymarket.candidate --id 1     # Review details
      3. mix polymarket.investigate --id 1   # Start investigation
      4. mix polymarket.confirm --id 1       # Confirm as insider

  ### Reference Case Discovery Workflow

      1. mix polymarket.discover --reference-case "Case Name"  # Find candidate markets
      2. mix polymarket.confirm --reference-case "Case Name" --condition 0x...  # Confirm match
      3. mix polymarket.ingest --subgraph --reference-case "Case Name"  # Ingest trades

  After candidate confirmation, run the feedback loop:

      mix polymarket.feedback
  """

  use Mix.Task
  alias VolfefeMachine.Polymarket
  alias VolfefeMachine.Polymarket.InsiderReferenceCase
  alias VolfefeMachine.Polymarket.SubgraphClient
  alias VolfefeMachine.Repo

  @shortdoc "Confirm candidate as insider or reference case market match"

  @impl Mix.Task
  def run(args) do
    Mix.Task.run("app.start")

    {opts, _, _} = OptionParser.parse(args,
      switches: [
        # Candidate confirmation
        id: :integer,
        notes: :string,
        evidence: :string,
        confidence: :string,
        confirmed_by: :string,
        # Reference case confirmation
        reference_case: :string,
        condition: :string,
        slug: :string,
        question: :string
      ],
      aliases: [n: :notes, e: :evidence, c: :confidence]
    )

    cond do
      # Reference case market confirmation mode
      opts[:reference_case] && opts[:condition] ->
        confirm_reference_case_market(opts)

      opts[:reference_case] ->
        Mix.shell().error("Error: --condition is required with --reference-case")
        Mix.shell().info("Usage: mix polymarket.confirm --reference-case \"Case Name\" --condition 0x...")

      # Candidate confirmation mode
      opts[:id] ->
        confidence = opts[:confidence] || "confirmed"
        if confidence not in ["confirmed", "likely"] do
          Mix.shell().error("Error: --confidence must be 'confirmed' or 'likely'")
        else
          confirm_candidate(opts[:id], confidence, opts)
        end

      true ->
        Mix.shell().error("Error: --id or --reference-case is required")
        Mix.shell().info("")
        Mix.shell().info("Usage:")
        Mix.shell().info("  mix polymarket.confirm --id ID [--notes NOTES]")
        Mix.shell().info("  mix polymarket.confirm --reference-case \"Case Name\" --condition 0x...")
    end
  end

  # ============================================================================
  # Reference Case Market Confirmation
  # ============================================================================

  defp confirm_reference_case_market(opts) do
    case_name = opts[:reference_case]
    condition_id = opts[:condition]

    Mix.shell().info("")
    Mix.shell().info("🔍 Confirming market for reference case: #{case_name}")
    Mix.shell().info("")

    case Repo.get_by(InsiderReferenceCase, case_name: case_name) do
      nil ->
        Mix.shell().error("Reference case not found: #{case_name}")
        Mix.shell().info("")
        Mix.shell().info("Available reference cases:")
        list_available_cases()

      ref_case ->
        if ref_case.condition_id && ref_case.condition_id != condition_id do
          Mix.shell().info("⚠️  Reference case already has condition_id: #{ref_case.condition_id}")
          Mix.shell().info("   You are about to replace it with: #{condition_id}")
          Mix.shell().info("")
        end

        # Fetch market info from subgraph if not provided
        {slug, question} = get_market_info(condition_id, opts)

        # Update the reference case
        attrs = %{
          condition_id: condition_id,
          market_slug: slug,
          market_question: question
        }

        case ref_case |> Ecto.Changeset.change(attrs) |> Repo.update() do
          {:ok, updated} ->
            Mix.shell().info("✅ Market confirmed for '#{case_name}'")
            Mix.shell().info("")
            Mix.shell().info("   Condition ID: #{updated.condition_id}")
            Mix.shell().info("   Market Slug:  #{updated.market_slug || "N/A"}")
            Mix.shell().info("   Question:     #{truncate(updated.market_question, 60)}")
            Mix.shell().info("   Event Date:   #{updated.event_date || "Not set"}")

            # Show discovered wallets if available (Phase 3)
            display_discovered_wallets(updated)

            Mix.shell().info("")
            Mix.shell().info("Next steps:")
            Mix.shell().info("  1. mix polymarket.ingest --subgraph --reference-case \"#{case_name}\"")
            if length(updated.discovered_wallets || []) > 0 do
              Mix.shell().info("  2. Investigate discovered wallets with pattern analysis")
            end
            Mix.shell().info("")

          {:error, changeset} ->
            Mix.shell().error("Failed to update reference case:")
            print_errors(changeset)
        end
    end
  end

  defp get_market_info(condition_id, opts) do
    slug = opts[:slug]
    question = opts[:question]

    # If both provided, use them
    if slug && question do
      {slug, question}
    else
      # Try to fetch from subgraph
      Mix.shell().info("   Fetching market info from subgraph...")

      case SubgraphClient.get_market_info(condition_id) do
        {:ok, market_info} ->
          fetched_slug = market_info["slug"] || slug
          fetched_question = market_info["question"] || question
          Mix.shell().info("   Found: #{truncate(fetched_question || "Unknown", 50)}")
          {fetched_slug, fetched_question}

        {:error, _reason} ->
          Mix.shell().info("   Could not fetch market info, using provided values")
          {slug, question}
      end
    end
  end

  defp list_available_cases do
    cases = Repo.all(InsiderReferenceCase)
            |> Enum.filter(&(&1.platform == "polymarket"))
            |> Enum.take(10)

    if Enum.empty?(cases) do
      Mix.shell().info("  (No Polymarket reference cases found)")
    else
      Enum.each(cases, fn c ->
        status = if c.condition_id, do: "✓", else: "○"
        Mix.shell().info("  #{status} #{c.case_name}")
      end)
    end
  end

  defp truncate(nil, _), do: "N/A"
  defp truncate(str, max) when byte_size(str) <= max, do: str
  defp truncate(str, max), do: String.slice(str, 0, max - 3) <> "..."

  defp display_discovered_wallets(ref_case) do
    wallets = ref_case.discovered_wallets || []
    condition_ids = ref_case.discovered_condition_ids || []

    if length(wallets) > 0 || length(condition_ids) > 0 do
      Mix.shell().info("")
      Mix.shell().info("   📊 Discovery Data:")

      if length(condition_ids) > 0 do
        Mix.shell().info("   Candidate markets found: #{length(condition_ids)}")
      end

      if length(wallets) > 0 do
        Mix.shell().info("")
        Mix.shell().info("   🔍 Top Suspicious Wallets (#{length(wallets)} found):")

        wallets
        |> Enum.take(5)
        |> Enum.with_index(1)
        |> Enum.each(fn {wallet, idx} ->
          address = wallet["address"] || "unknown"
          address_short = truncate(address, 14)
          volume = wallet["total_volume"] || "0"
          score = wallet["suspicion_score"] || 0
          hours = wallet["hours_before_event"]

          timing = if hours, do: "#{hours}h before", else: "N/A"

          Mix.shell().info("      #{idx}. #{address_short}... | $#{format_volume(volume)} | Score: #{score} | #{timing}")
        end)

        if length(wallets) > 5 do
          Mix.shell().info("      ... and #{length(wallets) - 5} more")
        end
      end

      if ref_case.discovery_run_at do
        Mix.shell().info("")
        Mix.shell().info("   Discovery run: #{format_datetime(ref_case.discovery_run_at)}")
      end
    end
  end

  defp format_volume(vol) when is_binary(vol) do
    case Decimal.parse(vol) do
      {d, _} -> Decimal.round(d, 2) |> Decimal.to_string()
      :error -> vol
    end
  end
  defp format_volume(vol), do: "#{vol}"

  defp format_datetime(nil), do: "N/A"
  defp format_datetime(%DateTime{} = dt), do: DateTime.to_string(dt)
  defp format_datetime(other), do: "#{other}"

  defp confirm_candidate(id, confidence, opts) do
    confirmed_by = opts[:confirmed_by] || "cli"

    case Polymarket.get_investigation_candidate(id) do
      nil ->
        Mix.shell().error("Candidate ##{id} not found")

      candidate ->
        case candidate.status do
          "resolved" ->
            Mix.shell().info("")
            Mix.shell().info("⚠️  Candidate ##{id} has already been resolved")
            Mix.shell().info("   Resolution: #{get_resolution(candidate)}")
            Mix.shell().info("   Resolved: #{relative_time(candidate.resolved_at)}")
            Mix.shell().info("")

          _ ->
            do_confirm(candidate, confidence, opts, confirmed_by)
        end
    end
  end

  defp do_confirm(candidate, confidence, opts, confirmed_by) do
    resolution = if confidence == "confirmed", do: "confirmed_insider", else: "likely_insider"

    evidence = if opts[:evidence], do: %{"link" => opts[:evidence]}, else: %{}

    resolve_opts = [
      evidence: evidence,
      notes: opts[:notes],
      resolved_by: confirmed_by
    ]

    case Polymarket.resolve_candidate(candidate, resolution, resolve_opts) do
      {:ok, updated} ->
        Mix.shell().info("")
        Mix.shell().info("✅ Confirmed candidate ##{candidate.id} as insider")
        Mix.shell().info("   Wallet: #{format_wallet(updated.wallet_address)}")
        Mix.shell().info("   Profit: #{format_money(updated.estimated_profit)}")
        Mix.shell().info("   Confidence: #{confidence}")

        if opts[:notes] do
          Mix.shell().info("   Notes: #{opts[:notes]}")
        end

        Mix.shell().info("")
        Mix.shell().info("Created ConfirmedInsider record.")
        Mix.shell().info("Run 'mix polymarket.feedback' to retrain patterns.")
        Mix.shell().info("")

        # Show quick status
        show_feedback_status()

      {:error, changeset} ->
        Mix.shell().error("Failed to confirm candidate:")
        print_errors(changeset)
    end
  end

  defp show_feedback_status do
    stats = Polymarket.feedback_loop_stats()

    Mix.shell().info("Current feedback loop status:")
    Mix.shell().info("├─ Confirmed Insiders: #{stats.confirmed_insiders.total}")
    Mix.shell().info("├─ Trained: #{stats.confirmed_insiders.trained}")
    Mix.shell().info("└─ Untrained: #{stats.confirmed_insiders.untrained}")

    if stats.confirmed_insiders.untrained > 0 do
      Mix.shell().info("")
      Mix.shell().info("⚠️  #{stats.confirmed_insiders.untrained} untrained insider(s) - run feedback loop to update patterns")
    end
  end

  defp get_resolution(%{resolution_evidence: %{"resolution" => res}}), do: res
  defp get_resolution(_), do: "unknown"

  defp print_errors(%Ecto.Changeset{} = changeset) do
    Ecto.Changeset.traverse_errors(changeset, fn {msg, opts} ->
      Enum.reduce(opts, msg, fn {key, value}, acc ->
        String.replace(acc, "%{#{key}}", to_string(value))
      end)
    end)
    |> Enum.each(fn {field, errors} ->
      Mix.shell().error("  #{field}: #{Enum.join(errors, ", ")}")
    end)
  end

  defp format_wallet(nil), do: "Unknown"
  defp format_wallet(address) when byte_size(address) > 10 do
    "#{String.slice(address, 0, 6)}...#{String.slice(address, -4, 4)}"
  end
  defp format_wallet(address), do: address

  defp format_money(nil), do: "N/A"
  defp format_money(%Decimal{} = d), do: "$#{Decimal.round(d, 2) |> Decimal.to_string()}"
  defp format_money(n), do: "$#{n}"

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
end
