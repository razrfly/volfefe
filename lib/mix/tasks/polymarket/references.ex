defmodule Mix.Tasks.Polymarket.References do
  @moduledoc """
  List known insider trading reference cases (ground truth data).

  Shows documented cases from Polymarket and other platforms for algorithm validation.

  ## Usage

      # List all reference cases
      mix polymarket.references

      # Filter by platform
      mix polymarket.references --platform polymarket
      mix polymarket.references --platform coinbase

      # Filter by status
      mix polymarket.references --status confirmed
      mix polymarket.references --status suspected

      # Filter by pattern type
      mix polymarket.references --pattern new_account_large_bet

      # Show detailed descriptions
      mix polymarket.references --verbose

  ## Options

      --platform    Filter by platform (polymarket, kalshi, nyse, nasdaq, coinbase, sportsbook)
      --status      Filter by status (confirmed, suspected, investigated, cleared)
      --category    Filter by category (politics, tech, crypto, sports, awards, corporate)
      --pattern     Filter by pattern type
      --limit       Maximum cases to show (default: all)
      --verbose     Show full descriptions and source URLs

  ## Pattern Types

      - new_account_large_bet     Fresh account makes unusually large wager
      - surge_before_secret       Volume spike before secret decision
      - embargo_breach            Bets when embargoed data becomes accessible
      - serial_front_running      Repeated wins across multiple events
      - pre_merger_options        Options activity before M&A announcements
      - executive_insider         Corporate insider trading on own company
      - pre_disclosure_options    Options before material disclosure
      - injury_info_leak          Sports bets on non-public injury info

  ## Example Output

      $ mix polymarket.references

      ═══════════════════════════════════════════════════════════════
      INSIDER REFERENCE CASES (GROUND TRUTH)
      ═══════════════════════════════════════════════════════════════

      Total: 9 cases (3 confirmed, 5 suspected, 1 investigated)

      ┌────┬──────────────────────┬────────────┬───────────┬─────────────┐
      │ ID │ Case Name            │ Platform   │ Status    │ Profit      │
      ├────┼──────────────────────┼────────────┼───────────┼─────────────┤
      │ 1  │ Venezuela/Maduro     │ polymarket │ suspected │ $400,000    │
      │ 2  │ Nobel Peace 2025     │ polymarket │ investig. │ $10,000     │
      │ 3  │ Coinbase Listing     │ coinbase   │ confirmed │ $1,100,000  │
      └────┴──────────────────────┴────────────┴───────────┴─────────────┘

  """

  use Mix.Task
  import Ecto.Query
  alias VolfefeMachine.Repo
  alias VolfefeMachine.Polymarket.InsiderReferenceCase

  @shortdoc "List known insider trading reference cases"

  @impl Mix.Task
  def run(args) do
    Mix.Task.run("app.start")

    {opts, _, _} = OptionParser.parse(args,
      switches: [
        platform: :string,
        status: :string,
        category: :string,
        pattern: :string,
        limit: :integer,
        verbose: :boolean,
        seed: :boolean
      ],
      aliases: [p: :platform, s: :status, c: :category, l: :limit, v: :verbose]
    )

    # Check if --seed flag is passed
    if opts[:seed] do
      run_seeds()
    else
      list_cases(opts)
    end
  end

  defp run_seeds do
    Mix.shell().info("")
    Mix.shell().info("Running insider reference case seeds...")
    Mix.shell().info("")

    seed_file = Path.join([File.cwd!(), "priv", "repo", "seeds", "insider_reference_cases.exs"])

    if File.exists?(seed_file) do
      Code.eval_file(seed_file)
      Mix.shell().info("")
      Mix.shell().info("✅ Seeds completed successfully!")
    else
      Mix.shell().error("❌ Seed file not found: #{seed_file}")
    end
  end

  defp list_cases(opts) do
    print_header()

    query = build_query(opts)
    cases = Repo.all(query)

    if length(cases) == 0 do
      Mix.shell().info("No reference cases found.")
      Mix.shell().info("")
      Mix.shell().info("To seed reference cases:")
      Mix.shell().info("  mix polymarket.references --seed")
    else
      stats = calculate_stats()
      print_summary(stats)
      print_table(cases, opts[:verbose] || false)
      print_breakdown(stats)

      if opts[:verbose] do
        print_detailed(cases)
      end
    end

    print_footer()
  end

  defp build_query(opts) do
    query = from(r in InsiderReferenceCase, order_by: [desc: r.event_date])

    query = if opts[:platform] do
      from r in query, where: r.platform == ^opts[:platform]
    else
      query
    end

    query = if opts[:status] do
      from r in query, where: r.status == ^opts[:status]
    else
      query
    end

    query = if opts[:category] do
      from r in query, where: r.category == ^opts[:category]
    else
      query
    end

    query = if opts[:pattern] do
      from r in query, where: r.pattern_type == ^opts[:pattern]
    else
      query
    end

    if opts[:limit] do
      from r in query, limit: ^opts[:limit]
    else
      query
    end
  end

  defp calculate_stats do
    cases = Repo.all(InsiderReferenceCase)

    %{
      total: length(cases),
      by_status: Enum.frequencies_by(cases, & &1.status),
      by_platform: Enum.frequencies_by(cases, & &1.platform),
      by_category: Enum.frequencies_by(cases, & &1.category),
      by_pattern: Enum.frequencies_by(cases, & &1.pattern_type),
      total_profit: cases
        |> Enum.map(& &1.reported_profit)
        |> Enum.reject(&is_nil/1)
        |> Enum.reduce(Decimal.new(0), &Decimal.add/2)
    }
  end

  defp print_header do
    Mix.shell().info("")
    Mix.shell().info(String.duplicate("═", 70))
    Mix.shell().info("INSIDER REFERENCE CASES (GROUND TRUTH)")
    Mix.shell().info(String.duplicate("═", 70))
    Mix.shell().info("")
  end

  defp print_footer do
    Mix.shell().info(String.duplicate("─", 70))
    Mix.shell().info("Use --verbose for full descriptions and sources")
    Mix.shell().info("Use --seed to populate reference cases from seed file")
    Mix.shell().info("")
  end

  defp print_summary(stats) do
    status_parts = stats.by_status
      |> Enum.sort_by(fn {_k, v} -> -v end)
      |> Enum.map(fn {status, count} -> "#{count} #{status}" end)
      |> Enum.join(", ")

    Mix.shell().info("Total: #{stats.total} cases (#{status_parts})")
    Mix.shell().info("Total reported profit: #{format_money(stats.total_profit)}")
    Mix.shell().info("")
  end

  defp print_table(cases, verbose) do
    Mix.shell().info("┌─────┬────────────────────────┬────────────┬────────────┬─────────────┐")
    Mix.shell().info("│ ID  │ Case Name              │ Platform   │ Status     │ Profit      │")
    Mix.shell().info("├─────┼────────────────────────┼────────────┼────────────┼─────────────┤")

    Enum.each(cases, fn ref_case ->
      id = String.pad_trailing("#{ref_case.id}", 3)
      name = ref_case.case_name
        |> String.slice(0, 20)
        |> String.pad_trailing(22)
      platform = String.pad_trailing(ref_case.platform || "N/A", 10)
      status = String.pad_trailing(truncate_status(ref_case.status), 10)
      profit = String.pad_trailing(format_money_short(ref_case.reported_profit), 11)

      Mix.shell().info("│ #{id} │ #{name} │ #{platform} │ #{status} │ #{profit} │")

      if verbose do
        date = if ref_case.event_date, do: Date.to_string(ref_case.event_date), else: "N/A"
        pattern = ref_case.pattern_type || "N/A"
        category = ref_case.category || "N/A"
        Mix.shell().info("│     │  Date: #{String.pad_trailing(date, 12)} Pattern: #{String.pad_trailing(pattern, 25)} │")
        Mix.shell().info("│     │  Category: #{String.pad_trailing(category, 62)} │")
      end
    end)

    Mix.shell().info("└─────┴────────────────────────┴────────────┴────────────┴─────────────┘")
    Mix.shell().info("")
  end

  defp print_breakdown(stats) do
    # By Platform
    if map_size(stats.by_platform) > 0 do
      Mix.shell().info("By Platform:")
      print_breakdown_items(stats.by_platform)
    end

    # By Pattern
    if map_size(stats.by_pattern) > 0 do
      Mix.shell().info("By Pattern:")
      print_breakdown_items(stats.by_pattern)
    end
  end

  defp print_breakdown_items(items) do
    sorted = items
      |> Map.to_list()
      |> Enum.reject(fn {k, _v} -> is_nil(k) end)
      |> Enum.sort_by(fn {_k, v} -> -v end)

    count = length(sorted)

    sorted
    |> Enum.with_index()
    |> Enum.each(fn {{key, cnt}, idx} ->
      prefix = if idx == count - 1, do: "└─", else: "├─"
      Mix.shell().info("#{prefix} #{key}: #{cnt}")
    end)

    Mix.shell().info("")
  end

  defp print_detailed(cases) do
    Mix.shell().info("═══ DETAILED DESCRIPTIONS ═══")
    Mix.shell().info("")

    Enum.each(cases, fn ref_case ->
      Mix.shell().info("#{ref_case.case_name} (#{ref_case.platform})")
      Mix.shell().info(String.duplicate("─", 50))

      if ref_case.description do
        ref_case.description
        |> String.trim()
        |> String.split("\n")
        |> Enum.each(fn line ->
          Mix.shell().info("  #{String.trim(line)}")
        end)
      end

      if ref_case.source_urls && length(ref_case.source_urls) > 0 do
        Mix.shell().info("")
        Mix.shell().info("  Sources:")
        Enum.each(ref_case.source_urls, fn url ->
          Mix.shell().info("    • #{url}")
        end)
      end

      Mix.shell().info("")
    end)
  end

  defp truncate_status(nil), do: "N/A"
  defp truncate_status("investigated"), do: "investig."
  defp truncate_status(s), do: s

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
