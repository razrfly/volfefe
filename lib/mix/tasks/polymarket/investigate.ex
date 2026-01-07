defmodule Mix.Tasks.Polymarket.Investigate do
  @moduledoc """
  Start investigation on a candidate.

  Changes candidate status to "investigating" and assigns investigator.

  ## Usage

      # Start investigating a candidate
      mix polymarket.investigate --id 1

      # Assign to specific investigator
      mix polymarket.investigate --id 1 --assignee analyst@example.com

  ## Options

      --id        Candidate ID (required)
      --assignee  Who is investigating (default: "cli")

  ## Examples

      $ mix polymarket.investigate --id 3

      ✅ Started investigation on candidate #3
         Status:   investigating
         Assigned: cli
         Started:  just now

      Next steps:
      - Review candidate: mix polymarket.candidate --id 3
      - Resolve: mix polymarket.resolve --id 3 --resolution confirmed_insider
      - Or clear: mix polymarket.resolve --id 3 --resolution cleared
  """

  use Mix.Task
  alias VolfefeMachine.Polymarket

  @shortdoc "Start investigation on a candidate"

  @impl Mix.Task
  def run(args) do
    Mix.Task.run("app.start")

    {opts, _, _} = OptionParser.parse(args,
      switches: [
        id: :integer,
        assignee: :string
      ],
      aliases: [a: :assignee]
    )

    case opts[:id] do
      nil ->
        Mix.shell().error("Error: --id is required")
        Mix.shell().info("Usage: mix polymarket.investigate --id ID [--assignee EMAIL]")

      id ->
        assignee = opts[:assignee] || "cli"
        start_investigation(id, assignee)
    end
  end

  defp start_investigation(id, assignee) do
    case Polymarket.get_investigation_candidate(id) do
      nil ->
        Mix.shell().error("Candidate ##{id} not found")

      candidate ->
        case candidate.status do
          "investigating" ->
            Mix.shell().info("")
            Mix.shell().info("⚠️  Candidate ##{id} is already under investigation")
            Mix.shell().info("   Assigned to: #{candidate.assigned_to || "unknown"}")
            Mix.shell().info("   Started: #{relative_time(candidate.investigation_started_at)}")
            Mix.shell().info("")

          "resolved" ->
            Mix.shell().info("")
            Mix.shell().info("⚠️  Candidate ##{id} has already been resolved")
            Mix.shell().info("   Resolved: #{relative_time(candidate.resolved_at)}")
            Mix.shell().info("   By: #{candidate.resolved_by || "unknown"}")
            Mix.shell().info("")

          "dismissed" ->
            Mix.shell().info("")
            Mix.shell().info("⚠️  Candidate ##{id} was dismissed")
            Mix.shell().info("   Notes: #{candidate.investigation_notes || "none"}")
            Mix.shell().info("")

          _ ->
            case Polymarket.start_investigation(candidate, assignee) do
              {:ok, updated} ->
                Mix.shell().info("")
                Mix.shell().info("✅ Started investigation on candidate ##{id}")
                Mix.shell().info("   Status:   #{updated.status}")
                Mix.shell().info("   Assigned: #{updated.assigned_to}")
                Mix.shell().info("   Started:  #{relative_time(updated.investigation_started_at)}")
                Mix.shell().info("")
                Mix.shell().info("Next steps:")
                Mix.shell().info("- Review candidate: mix polymarket.candidate --id #{id}")
                Mix.shell().info("- Resolve: mix polymarket.resolve --id #{id} --resolution confirmed_insider")
                Mix.shell().info("- Or clear: mix polymarket.resolve --id #{id} --resolution cleared")
                Mix.shell().info("")

              {:error, changeset} ->
                Mix.shell().error("Failed to start investigation:")
                print_errors(changeset)
            end
        end
    end
  end

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
