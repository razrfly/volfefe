defmodule Mix.Tasks.Polymarket.Resolve do
  @moduledoc """
  Resolve an investigation candidate.

  Marks candidate as resolved with a resolution type and optional notes.

  ## Usage

      # Confirm as insider
      mix polymarket.resolve --id 1 --resolution confirmed_insider

      # Clear (not an insider)
      mix polymarket.resolve --id 1 --resolution cleared

      # With notes
      mix polymarket.resolve --id 1 --resolution confirmed_insider --notes "News article timing match"

      # With evidence link
      mix polymarket.resolve --id 1 --resolution confirmed_insider --evidence "https://example.com/article"

  ## Resolution Types

      confirmed_insider   - Confirmed insider trading (creates ConfirmedInsider record)
      likely_insider      - Likely insider but not confirmed (creates ConfirmedInsider with lower confidence)
      cleared             - Cleared, not suspicious
      insufficient_evidence - Not enough evidence to determine

  ## Options

      --id          Candidate ID (required)
      --resolution  Resolution type (required)
      --notes       Investigation notes
      --evidence    Evidence URL or reference
      --resolved-by Who resolved it (default: "cli")

  ## Examples

      $ mix polymarket.resolve --id 1 --resolution confirmed_insider --notes "Trade 30min before announcement"

      ✅ Resolved candidate #1 as confirmed_insider
         Created ConfirmedInsider record
         Wallet: 0x348a...f2c1
         Profit: $12,450

      Feedback loop will retrain patterns on next run.
  """

  use Mix.Task
  alias VolfefeMachine.Polymarket

  @shortdoc "Resolve an investigation candidate"

  @valid_resolutions ~w(confirmed_insider likely_insider cleared insufficient_evidence)

  @impl Mix.Task
  def run(args) do
    Mix.Task.run("app.start")

    {opts, _, _} = OptionParser.parse(args,
      switches: [
        id: :integer,
        resolution: :string,
        notes: :string,
        evidence: :string,
        resolved_by: :string
      ],
      aliases: [r: :resolution, n: :notes, e: :evidence]
    )

    cond do
      opts[:id] == nil ->
        Mix.shell().error("Error: --id is required")
        print_usage()

      opts[:resolution] == nil ->
        Mix.shell().error("Error: --resolution is required")
        print_usage()

      opts[:resolution] not in @valid_resolutions ->
        Mix.shell().error("Error: Invalid resolution '#{opts[:resolution]}'")
        Mix.shell().info("Valid resolutions: #{Enum.join(@valid_resolutions, ", ")}")

      true ->
        resolve_candidate(opts)
    end
  end

  defp print_usage do
    Mix.shell().info("")
    Mix.shell().info("Usage: mix polymarket.resolve --id ID --resolution RESOLUTION [options]")
    Mix.shell().info("")
    Mix.shell().info("Resolutions:")
    Mix.shell().info("  confirmed_insider    - Confirmed insider trading")
    Mix.shell().info("  likely_insider       - Likely insider (lower confidence)")
    Mix.shell().info("  cleared              - Not an insider")
    Mix.shell().info("  insufficient_evidence - Cannot determine")
    Mix.shell().info("")
  end

  defp resolve_candidate(opts) do
    id = opts[:id]
    resolution = opts[:resolution]
    resolved_by = opts[:resolved_by] || "cli"

    case Polymarket.get_investigation_candidate(id) do
      nil ->
        Mix.shell().error("Candidate ##{id} not found")

      candidate ->
        if candidate.status == "resolved" do
          Mix.shell().info("")
          Mix.shell().info("⚠️  Candidate ##{id} has already been resolved")
          Mix.shell().info("   Resolution: #{get_resolution(candidate)}")
          Mix.shell().info("   Resolved: #{relative_time(candidate.resolved_at)}")
          Mix.shell().info("   By: #{candidate.resolved_by || "unknown"}")
          Mix.shell().info("")
        else
          do_resolve(candidate, resolution, opts, resolved_by)
        end
    end
  end

  defp do_resolve(candidate, resolution, opts, resolved_by) do
    evidence = if opts[:evidence], do: %{"link" => opts[:evidence]}, else: %{}

    resolve_opts = [
      evidence: evidence,
      notes: opts[:notes],
      resolved_by: resolved_by
    ]

    case Polymarket.resolve_candidate(candidate, resolution, resolve_opts) do
      {:ok, updated} ->
        Mix.shell().info("")
        Mix.shell().info("✅ Resolved candidate ##{candidate.id} as #{resolution}")

        if resolution in ["confirmed_insider", "likely_insider"] do
          Mix.shell().info("   Created ConfirmedInsider record")
          Mix.shell().info("   Wallet: #{format_wallet(updated.wallet_address)}")
          Mix.shell().info("   Profit: #{format_money(updated.estimated_profit)}")
          Mix.shell().info("")
          Mix.shell().info("Feedback loop will retrain patterns on next run:")
          Mix.shell().info("  mix polymarket.feedback")
        else
          Mix.shell().info("   Status: resolved (#{resolution})")
        end

        if opts[:notes] do
          Mix.shell().info("   Notes: #{opts[:notes]}")
        end

        Mix.shell().info("")

      {:error, changeset} ->
        Mix.shell().error("Failed to resolve candidate:")
        print_errors(changeset)
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
