defmodule Mix.Tasks.Polymarket.Insiders do
  @moduledoc """
  List confirmed insiders.

  Shows all confirmed insider wallets with their profits, confidence levels,
  and training status.

  ## Usage

      # List all confirmed insiders
      mix polymarket.insiders

      # Filter by confidence level
      mix polymarket.insiders --confidence confirmed
      mix polymarket.insiders --confidence likely

      # Filter by training status
      mix polymarket.insiders --trained
      mix polymarket.insiders --untrained

      # Limit results
      mix polymarket.insiders --limit 20

  ## Options

      --confidence   Filter by confidence level (confirmed, likely, suspected)
      --trained      Show only insiders used for training
      --untrained    Show only insiders not yet used for training
      --limit        Maximum insiders to show (default: 50)
      --verbose      Show full wallet addresses and notes

  ## Examples

      $ mix polymarket.insiders

      ═══════════════════════════════════════════════════════════════
      POLYMARKET CONFIRMED INSIDERS
      ═══════════════════════════════════════════════════════════════

      Total: 5 insiders ($45,230 estimated profit)

      ┌────┬─────────────────┬────────────┬────────────┬─────────┐
      │ ID │ Wallet          │ Profit     │ Confidence │ Trained │
      ├────┼─────────────────┼────────────┼────────────┼─────────┤
      │ 1  │ 0xbacd...b35    │ $12,450    │ confirmed  │ ✅      │
      │ 2  │ 0x348a...2c1    │ $8,230     │ confirmed  │ ✅      │
      │ 3  │ 0x8912...a4f    │ $6,890     │ likely     │ ❌      │
      └────┴─────────────────┴────────────┴────────────┴─────────┘

      By Confidence:
      ├─ confirmed: 2
      └─ likely: 1

  """

  use Mix.Task
  alias VolfefeMachine.Polymarket

  @shortdoc "List confirmed insiders"

  @impl Mix.Task
  def run(args) do
    Mix.Task.run("app.start")

    {opts, _, _} = OptionParser.parse(args,
      switches: [
        confidence: :string,
        trained: :boolean,
        untrained: :boolean,
        limit: :integer,
        verbose: :boolean
      ],
      aliases: [c: :confidence, l: :limit, v: :verbose]
    )

    print_header()

    # Build query options
    query_opts = []
    query_opts = if opts[:confidence], do: Keyword.put(query_opts, :confidence_level, opts[:confidence]), else: query_opts
    query_opts = if opts[:trained], do: Keyword.put(query_opts, :used_for_training, true), else: query_opts
    query_opts = if opts[:untrained], do: Keyword.put(query_opts, :used_for_training, false), else: query_opts
    query_opts = Keyword.put(query_opts, :limit, opts[:limit] || 50)

    insiders = Polymarket.list_confirmed_insiders(query_opts)
    stats = Polymarket.confirmed_insider_stats()

    if length(insiders) == 0 do
      Mix.shell().info("No confirmed insiders found.")
      Mix.shell().info("")
      Mix.shell().info("To confirm insiders:")
      Mix.shell().info("  mix polymarket.candidates")
      Mix.shell().info("  mix polymarket.confirm --id ID")
    else
      # Summary
      Mix.shell().info("Total: #{stats.total} insiders ($#{format_money_short(stats.total_estimated_profit)} estimated profit)")
      Mix.shell().info("")

      # Table
      print_table(insiders, opts[:verbose] || false)

      # Stats
      print_stats(stats)
    end

    print_footer()
  end

  defp print_header do
    Mix.shell().info("")
    Mix.shell().info(String.duplicate("═", 65))
    Mix.shell().info("POLYMARKET CONFIRMED INSIDERS")
    Mix.shell().info(String.duplicate("═", 65))
    Mix.shell().info("")
  end

  defp print_footer do
    Mix.shell().info(String.duplicate("─", 65))
    Mix.shell().info("Run feedback: mix polymarket.feedback")
    Mix.shell().info("")
  end

  defp print_table(insiders, verbose) do
    Mix.shell().info("┌─────┬─────────────────┬────────────┬────────────┬─────────┐")
    Mix.shell().info("│ ID  │ Wallet          │ Profit     │ Confidence │ Trained │")
    Mix.shell().info("├─────┼─────────────────┼────────────┼────────────┼─────────┤")

    Enum.each(insiders, fn insider ->
      id = String.pad_trailing("#{insider.id}", 3)
      wallet = if verbose do
        String.pad_trailing(insider.wallet_address || "N/A", 15)
      else
        String.pad_trailing(format_wallet(insider.wallet_address), 15)
      end
      profit = String.pad_trailing(format_money(insider.estimated_profit), 10)
      confidence = String.pad_trailing(insider.confidence_level || "N/A", 10)
      trained = if insider.used_for_training, do: "✅     ", else: "❌     "

      Mix.shell().info("│ #{id} │ #{wallet} │ #{profit} │ #{confidence} │ #{trained} │")
    end)

    Mix.shell().info("└─────┴─────────────────┴────────────┴────────────┴─────────┘")
    Mix.shell().info("")
  end

  defp print_stats(stats) do
    if map_size(stats.by_confidence) > 0 do
      Mix.shell().info("By Confidence:")
      confidence_items = Map.to_list(stats.by_confidence)
      count = length(confidence_items)

      confidence_items
      |> Enum.sort_by(fn {_k, v} -> -v end)
      |> Enum.with_index()
      |> Enum.each(fn {{level, cnt}, idx} ->
        prefix = if idx == count - 1, do: "└─", else: "├─"
        Mix.shell().info("#{prefix} #{level}: #{cnt}")
      end)
      Mix.shell().info("")
    end

    if map_size(stats.by_source) > 0 do
      Mix.shell().info("By Source:")
      source_items = Map.to_list(stats.by_source)
      count = length(source_items)

      source_items
      |> Enum.sort_by(fn {_k, v} -> -v end)
      |> Enum.with_index()
      |> Enum.each(fn {{source, cnt}, idx} ->
        prefix = if idx == count - 1, do: "└─", else: "├─"
        Mix.shell().info("#{prefix} #{source || "unknown"}: #{cnt}")
      end)
      Mix.shell().info("")
    end
  end

  defp format_wallet(nil), do: "Unknown"
  defp format_wallet(address) when byte_size(address) > 10 do
    "#{String.slice(address, 0, 6)}...#{String.slice(address, -3, 3)}"
  end
  defp format_wallet(address), do: address

  defp format_money(nil), do: "N/A"
  defp format_money(%Decimal{} = d), do: "$#{Decimal.round(d, 0) |> Decimal.to_string()}"
  defp format_money(n), do: "$#{round(n)}"

  defp format_money_short(nil), do: "N/A"
  defp format_money_short(amount) when is_number(amount) do
    cond do
      amount >= 1_000_000 -> "#{Float.round(amount / 1_000_000, 1)}M"
      amount >= 1_000 -> "#{Float.round(amount / 1_000, 1)}K"
      true -> "#{round(amount)}"
    end
  end
  defp format_money_short(%Decimal{} = d), do: format_money_short(Decimal.to_float(d))
end
