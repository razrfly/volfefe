defmodule Mix.Tasks.Polymarket.Rescore do
  @moduledoc """
  Rescore all trades with current baselines.

  Recalculates anomaly scores and insider probability for all scored trades
  using the latest baseline metrics.

  ## Usage

      # Rescore all trades
      mix polymarket.rescore

      # Rescore with limit (for testing)
      mix polymarket.rescore --limit 1000

      # Force recalculation (clears existing scores first)
      mix polymarket.rescore --force

  ## Options

      --limit   Maximum trades to rescore (for testing)
      --batch   Batch size for processing (default: 500)
      --force   Force recalculation of all trades

  ## Examples

      $ mix polymarket.rescore

      ═══════════════════════════════════════════════════════════════
      POLYMARKET RESCORE
      ═══════════════════════════════════════════════════════════════

      Re-scoring 2,199 trades in batches of 500...

      Progress:
      ├─ Batch 1/5 complete
      ├─ Batch 2/5 complete
      ├─ Batch 3/5 complete
      ├─ Batch 4/5 complete
      └─ Batch 5/5 complete

      ✅ Re-scoring complete!
         Scored: 2,199
         Errors: 0

  ## Notes

  This operation can take several minutes for large datasets.
  Use --limit for testing to verify baselines are working correctly.
  """

  use Mix.Task
  alias VolfefeMachine.Polymarket

  @shortdoc "Rescore all trades with current baselines"

  @impl Mix.Task
  def run(args) do
    Mix.Task.run("app.start")

    {opts, _, _} = OptionParser.parse(args,
      switches: [
        limit: :integer,
        batch: :integer,
        force: :boolean
      ],
      aliases: [l: :limit, b: :batch, f: :force]
    )

    print_header()

    limit = opts[:limit]
    batch_size = opts[:batch] || 500

    Mix.shell().info("Re-scoring trades in batches of #{batch_size}...")
    if limit do
      Mix.shell().info("Limit: #{format_number(limit)} trades")
    end
    Mix.shell().info("")

    rescore_opts = [batch_size: batch_size]
    rescore_opts = if limit, do: Keyword.put(rescore_opts, :limit, limit), else: rescore_opts

    {:ok, result} = Polymarket.rescore_all_trades(rescore_opts)
    Mix.shell().info("✅ Re-scoring complete!")
    Mix.shell().info("   Scored: #{format_number(result.scored)}")
    Mix.shell().info("   Errors: #{result.errors}")

    if result.errors > 0 do
      Mix.shell().info("")
      Mix.shell().info("⚠️  #{result.errors} trades failed to rescore")
      Mix.shell().info("   Check logs for details")
    end

    Mix.shell().info("")

    print_footer()
  end

  defp print_header do
    Mix.shell().info("")
    Mix.shell().info(String.duplicate("═", 65))
    Mix.shell().info("POLYMARKET RESCORE")
    Mix.shell().info(String.duplicate("═", 65))
    Mix.shell().info("")
  end

  defp print_footer do
    Mix.shell().info(String.duplicate("─", 65))
    Mix.shell().info("Run discovery: mix polymarket.discover")
    Mix.shell().info("")
  end


  defp format_number(n) when is_integer(n) do
    n
    |> Integer.to_string()
    |> String.reverse()
    |> String.replace(~r/(\d{3})(?=\d)/, "\\1,")
    |> String.reverse()
  end
  defp format_number(n), do: "#{n}"
end
