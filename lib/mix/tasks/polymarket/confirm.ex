defmodule Mix.Tasks.Polymarket.Confirm do
  @moduledoc """
  Quick confirmation of a candidate as insider.

  Shortcut for `mix polymarket.resolve --id ID --resolution confirmed_insider`.

  ## Usage

      # Confirm candidate as insider
      mix polymarket.confirm --id 1

      # With notes
      mix polymarket.confirm --id 1 --notes "Timing analysis confirms pre-knowledge"

      # With evidence
      mix polymarket.confirm --id 1 --evidence "https://example.com/proof"

  ## Options

      --id          Candidate ID (required)
      --notes       Investigation notes
      --evidence    Evidence URL or reference
      --confidence  Confidence level: confirmed (default) or likely
      --confirmed-by Who confirmed it (default: "cli")

  ## Examples

      $ mix polymarket.confirm --id 1 --notes "Trade matched news timing exactly"

      ✅ Confirmed candidate #1 as insider
         Wallet: 0x348a...f2c1
         Profit: $12,450
         Confidence: confirmed

      Created ConfirmedInsider record.
      Run 'mix polymarket.feedback' to retrain patterns.

  ## Workflow

  This is typically the final step in the investigation workflow:

      1. mix polymarket.candidates           # Find suspicious candidates
      2. mix polymarket.candidate --id 1     # Review details
      3. mix polymarket.investigate --id 1   # Start investigation
      4. mix polymarket.confirm --id 1       # Confirm as insider

  After confirmation, run the feedback loop to improve pattern detection:

      mix polymarket.feedback
  """

  use Mix.Task
  alias VolfefeMachine.Polymarket

  @shortdoc "Confirm a candidate as insider"

  @impl Mix.Task
  def run(args) do
    Mix.Task.run("app.start")

    {opts, _, _} = OptionParser.parse(args,
      switches: [
        id: :integer,
        notes: :string,
        evidence: :string,
        confidence: :string,
        confirmed_by: :string
      ],
      aliases: [n: :notes, e: :evidence, c: :confidence]
    )

    case opts[:id] do
      nil ->
        Mix.shell().error("Error: --id is required")
        Mix.shell().info("Usage: mix polymarket.confirm --id ID [--notes NOTES] [--evidence URL]")

      id ->
        confidence = opts[:confidence] || "confirmed"
        if confidence not in ["confirmed", "likely"] do
          Mix.shell().error("Error: --confidence must be 'confirmed' or 'likely'")
        else
          confirm_candidate(id, confidence, opts)
        end
    end
  end

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
