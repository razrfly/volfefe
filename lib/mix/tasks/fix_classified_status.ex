defmodule Mix.Tasks.FixClassifiedStatus do
  @moduledoc """
  Synchronizes the classified status flag with actual classification records.

  This task fixes data inconsistencies where:
  - Content has `classified: true` but no classification records exist
  - Content has `classified: false` but classification records exist

  ## Usage

      # Preview what would be fixed (dry run)
      mix fix_classified_status --dry-run

      # Actually fix the data
      mix fix_classified_status

  ## When to Use

  - After manually deleting classifications from the database
  - After data migration or import issues
  - As a periodic health check/fix
  - When the "Unclassified Only" filter shows incorrect results
  """

  use Mix.Task

  alias VolfefeMachine.{Repo, Content}
  import Ecto.Query

  require Logger

  @shortdoc "Synchronizes classified status flag with actual classification records"

  @impl Mix.Task
  def run(args) do
    # Start the application for database access
    Mix.Task.run("app.start")

    # Parse arguments
    {opts, _remaining, _invalid} =
      OptionParser.parse(
        args,
        switches: [dry_run: :boolean],
        aliases: [d: :dry_run]
      )

    dry_run = opts[:dry_run] || false

    if dry_run do
      Mix.shell().info("\n🔍 DRY RUN MODE - No changes will be made\n")
    end

    Mix.shell().info("=" |> String.duplicate(80))
    Mix.shell().info("🔧 Classified Status Synchronization")
    Mix.shell().info("=" |> String.duplicate(80))
    Mix.shell().info("")

    # Find inconsistencies
    {incorrectly_classified, incorrectly_unclassified} = find_inconsistencies()

    # Report findings
    report_findings(incorrectly_classified, incorrectly_unclassified)

    # Fix if not dry run
    unless dry_run do
      fix_inconsistencies(incorrectly_classified, incorrectly_unclassified)
    end

    Mix.shell().info("")
    Mix.shell().info("=" |> String.duplicate(80))
    Mix.shell().info("✅ Task completed")
    Mix.shell().info("=" |> String.duplicate(80))
    Mix.shell().info("")
  end

  defp find_inconsistencies do
    # Find content marked as classified but has no classification records
    incorrectly_classified =
      from(c in VolfefeMachine.Content.Content,
        left_join: cl in assoc(c, :classification),
        where: c.classified == true and is_nil(cl.id),
        select: %{
          id: c.id,
          external_id: c.external_id,
          author: c.author,
          published_at: c.published_at
        }
      )
      |> Repo.all()

    # Find content marked as unclassified but has classification records
    incorrectly_unclassified =
      from(c in VolfefeMachine.Content.Content,
        join: cl in assoc(c, :classification),
        where: c.classified == false,
        select: %{
          id: c.id,
          external_id: c.external_id,
          author: c.author,
          sentiment: cl.sentiment,
          confidence: cl.confidence
        }
      )
      |> Repo.all()

    {incorrectly_classified, incorrectly_unclassified}
  end

  defp report_findings(incorrectly_classified, incorrectly_unclassified) do
    Mix.shell().info("📊 Findings:\n")

    # Report incorrectly classified
    if length(incorrectly_classified) > 0 do
      Mix.shell().error(
        "⚠️  Found #{length(incorrectly_classified)} content(s) marked as classified but with NO classification records:"
      )

      Mix.shell().info("")

      incorrectly_classified
      |> Enum.take(5)
      |> Enum.each(fn content ->
        Mix.shell().info("   • ID: #{content.id} | #{content.author} | #{content.external_id}")
      end)

      if length(incorrectly_classified) > 5 do
        Mix.shell().info("   ... and #{length(incorrectly_classified) - 5} more")
      end

      Mix.shell().info("")
    else
      Mix.shell().info("✅ No content incorrectly marked as classified")
    end

    # Report incorrectly unclassified
    if length(incorrectly_unclassified) > 0 do
      Mix.shell().error(
        "⚠️  Found #{length(incorrectly_unclassified)} content(s) marked as unclassified but WITH classification records:"
      )

      Mix.shell().info("")

      incorrectly_unclassified
      |> Enum.take(5)
      |> Enum.each(fn content ->
        Mix.shell().info(
          "   • ID: #{content.id} | #{content.author} | Sentiment: #{content.sentiment} (#{Float.round(content.confidence * 100, 1)}%)"
        )
      end)

      if length(incorrectly_unclassified) > 5 do
        Mix.shell().info("   ... and #{length(incorrectly_unclassified) - 5} more")
      end

      Mix.shell().info("")
    else
      Mix.shell().info("✅ No content incorrectly marked as unclassified")
    end

    # Summary
    total_issues = length(incorrectly_classified) + length(incorrectly_unclassified)

    if total_issues == 0 do
      Mix.shell().info("🎉 All content classified status flags are consistent!")
    else
      Mix.shell().info("📈 Total issues found: #{total_issues}")
    end

    Mix.shell().info("")
  end

  defp fix_inconsistencies(incorrectly_classified, incorrectly_unclassified) do
    Mix.shell().info("🔧 Applying fixes...\n")

    # Fix incorrectly classified (has flag but no records)
    if length(incorrectly_classified) > 0 do
      ids = Enum.map(incorrectly_classified, & &1.id)
      {count, _} =
        from(c in VolfefeMachine.Content.Content, where: c.id in ^ids)
        |> Repo.update_all(set: [classified: false])

      Mix.shell().info("✅ Marked #{count} content(s) as unclassified (removed incorrect flag)")
      Logger.info("Fixed #{count} incorrectly classified content records: #{inspect(ids)}")
    end

    # Fix incorrectly unclassified (has records but no flag)
    if length(incorrectly_unclassified) > 0 do
      ids = Enum.map(incorrectly_unclassified, & &1.id)
      {count, _} =
        from(c in VolfefeMachine.Content.Content, where: c.id in ^ids)
        |> Repo.update_all(set: [classified: true])

      Mix.shell().info("✅ Marked #{count} content(s) as classified (added missing flag)")
      Logger.info("Fixed #{count} incorrectly unclassified content records: #{inspect(ids)}")
    end

    Mix.shell().info("")
  end
end
