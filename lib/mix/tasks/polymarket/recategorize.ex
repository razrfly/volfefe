defmodule Mix.Tasks.Polymarket.Recategorize do
  @moduledoc """
  Re-categorize all markets based on improved keyword detection.

  Useful after updating categorization logic to apply changes to existing markets.

  ## Usage

      # Re-categorize all markets
      mix polymarket.recategorize

      # Preview changes without saving
      mix polymarket.recategorize --dry-run

      # Verbose output showing each change
      mix polymarket.recategorize --verbose

  ## Examples

      $ mix polymarket.recategorize --dry-run

      ═══════════════════════════════════════════════════════════════
      POLYMARKET RECATEGORIZE (DRY RUN)
      ═══════════════════════════════════════════════════════════════

      CATEGORY CHANGES
      ┌──────────────┬──────────────┬───────┐
      │ From         │ To           │ Count │
      ├──────────────┼──────────────┼───────┤
      │ other        │ politics     │ 15    │
      │ other        │ sports       │ 45    │
      │ other        │ crypto       │ 8     │
      │ other        │ entertainment│ 3     │
      └──────────────┴──────────────┴───────┘

      Would update 71 markets (dry run - no changes made)
  """

  use Mix.Task
  require Logger
  import Ecto.Query
  alias VolfefeMachine.Repo
  alias VolfefeMachine.Polymarket.Market

  @shortdoc "Re-categorize markets with improved keyword detection"

  @impl Mix.Task
  def run(args) do
    Mix.Task.run("app.start")

    {opts, _, _} = OptionParser.parse(args,
      switches: [
        dry_run: :boolean,
        verbose: :boolean
      ],
      aliases: [d: :dry_run, v: :verbose]
    )

    dry_run = opts[:dry_run] || false
    verbose = opts[:verbose] || false

    print_header(dry_run)

    # Get all markets
    markets = Repo.all(from m in Market, select: m)

    # Calculate new categories
    changes = Enum.reduce(markets, [], fn market, acc ->
      new_category = Market.categorize_from_question(market.question || "")

      if new_category != market.category do
        [{market, market.category, new_category} | acc]
      else
        acc
      end
    end)

    if length(changes) == 0 do
      Mix.shell().info("No category changes needed - all markets properly categorized!")
      Mix.shell().info("")
    else
      # Group changes by from -> to
      change_summary = changes
        |> Enum.group_by(fn {_, from, to} -> {from, to} end)
        |> Enum.map(fn {{from, to}, items} -> {from, to, length(items)} end)
        |> Enum.sort_by(fn {_, _, count} -> -count end)

      print_change_table(change_summary)

      if verbose do
        Mix.shell().info("")
        Mix.shell().info("DETAILED CHANGES")
        Enum.take(changes, 20) |> Enum.each(fn {market, from, to} ->
          Mix.shell().info("  #{from} → #{to}: #{truncate(market.question, 50)}")
        end)
        if length(changes) > 20 do
          Mix.shell().info("  ... and #{length(changes) - 20} more")
        end
        Mix.shell().info("")
      end

      if dry_run do
        Mix.shell().info("Would update #{length(changes)} markets (dry run - no changes made)")
      else
        # Apply changes
        updated = Enum.reduce(changes, 0, fn {market, _from, to}, acc ->
          case market
               |> Market.changeset(%{category: to})
               |> Repo.update() do
            {:ok, _} -> acc + 1
            {:error, _} -> acc
          end
        end)

        Mix.shell().info("✅ Updated #{updated} markets")
      end

      Mix.shell().info("")
    end

    # Show final distribution
    print_category_distribution()

    print_footer()
  end

  defp print_change_table(changes) do
    Mix.shell().info("CATEGORY CHANGES")
    Mix.shell().info("┌──────────────┬──────────────┬───────┐")
    Mix.shell().info("│ From         │ To           │ Count │")
    Mix.shell().info("├──────────────┼──────────────┼───────┤")

    Enum.each(changes, fn {from, to, count} ->
      from_str = String.pad_trailing(to_string(from || "nil"), 12)
      to_str = String.pad_trailing(to_string(to), 12)
      count_str = String.pad_trailing(to_string(count), 5)
      Mix.shell().info("│ #{from_str} │ #{to_str} │ #{count_str} │")
    end)

    Mix.shell().info("└──────────────┴──────────────┴───────┘")
    Mix.shell().info("")
  end

  defp print_category_distribution do
    counts = Repo.all(
      from m in Market,
        group_by: m.category,
        select: {m.category, count(m.id)},
        order_by: [desc: count(m.id)]
    )

    Mix.shell().info("CURRENT DISTRIBUTION")
    Mix.shell().info("┌──────────────┬───────┐")
    Mix.shell().info("│ Category     │ Count │")
    Mix.shell().info("├──────────────┼───────┤")

    Enum.each(counts, fn {cat, count} ->
      cat_str = String.pad_trailing(to_string(cat || "nil"), 12)
      count_str = String.pad_trailing(to_string(count), 5)
      Mix.shell().info("│ #{cat_str} │ #{count_str} │")
    end)

    Mix.shell().info("└──────────────┴───────┘")
    Mix.shell().info("")
  end

  defp print_header(dry_run) do
    suffix = if dry_run, do: " (DRY RUN)", else: ""
    Mix.shell().info("")
    Mix.shell().info(String.duplicate("═", 65))
    Mix.shell().info("POLYMARKET RECATEGORIZE#{suffix}")
    Mix.shell().info(String.duplicate("═", 65))
    Mix.shell().info("")
  end

  defp print_footer do
    Mix.shell().info(String.duplicate("─", 65))
    Mix.shell().info("Check coverage: mix polymarket.coverage")
    Mix.shell().info("")
  end

  defp truncate(nil, _), do: ""
  defp truncate(str, max_length) when is_binary(str) do
    if String.length(str) > max_length do
      String.slice(str, 0, max_length) <> "..."
    else
      str
    end
  end
end
