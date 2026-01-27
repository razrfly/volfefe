defmodule Mix.Tasks.Polymarket.FindRing do
  @moduledoc """
  Find coordinated trading ring from a seed wallet or market.

  Uses graph-based cluster detection to find wallets that trade the same
  markets with similar patterns, suggesting coordinated insider activity.

  ## Usage

      # Find ring from a seed wallet
      mix polymarket.find_ring 0x511374966ad5f98abf5a200b2d5ea94b46b9f0ba

      # Find ring from a market condition_id
      mix polymarket.find_ring --market 0xabc123...

      # Adjust similarity threshold
      mix polymarket.find_ring 0x5113... --threshold 0.5

  ## Options

      --market      Use market condition_id as seed (find wallets in that market)
      --threshold   Minimum similarity score (0-1, default: 0.3)
      --min-shared  Minimum shared markets (default: 2)
      --limit       Maximum ring members to show (default: 50)
      --verbose     Show detailed similarity breakdown
      --json        Output as JSON

  ## Algorithm

  1. Start with seed wallet (or get top wallets from seed market)
  2. Find all markets the seed wallet traded
  3. Find all other wallets that traded those same markets
  4. Calculate similarity score based on:
     - Shared markets ratio (40%)
     - Same-side trading ratio (30%)
     - Win rate similarity (20%)
     - Score similarity (10%)
  5. Expand cluster by finding wallets similar to multiple ring members
  6. Return ranked list of potential ring members

  ## Examples

      $ mix polymarket.find_ring 0x511374966ad5f98abf5a200b2d5ea94b46b9f0ba

      RING DETECTION
      ═══════════════════════════════════════════════════════════════

      SEED WALLET: 0x5113...f0ba
      ├─ Markets Traded: 7
      ├─ Total Trades:   19
      └─ Win Rate:       100%

      DETECTED RING (12 members)
      ├─ 0xa4bd...e8a2 - similarity: 0.89, 5 shared markets, 100% win
      ├─ 0x945a...a48c - similarity: 0.85, 4 shared markets, 95% win
      └─ ...

      RING STATISTICS
      ├─ Total Members:     12
      ├─ Total Trades:      156
      ├─ Aggregate Win Rate: 94%
      ├─ Total Volume:      $125,000
      └─ Primary Markets:   Elon Musk tweet counts
  """

  use Mix.Task
  import Ecto.Query
  alias VolfefeMachine.Repo
  alias VolfefeMachine.Polymarket
  alias VolfefeMachine.Polymarket.{Trade, TradeScore, Market}

  @shortdoc "Find coordinated trading ring from a seed"

  @impl Mix.Task
  def run(args) do
    Mix.Task.run("app.start")

    {opts, positional, _} = OptionParser.parse(args,
      switches: [
        market: :string,
        threshold: :float,
        min_shared: :integer,
        limit: :integer,
        verbose: :boolean,
        json: :boolean
      ],
      aliases: [m: :market, t: :threshold, l: :limit, v: :verbose, j: :json]
    )

    threshold = opts[:threshold] || 0.3
    min_shared = opts[:min_shared] || 2
    limit = opts[:limit] || 50

    cond do
      opts[:market] ->
        find_ring_from_market(opts[:market], threshold, min_shared, limit, opts)

      length(positional) > 0 ->
        [address | _] = positional
        find_ring_from_wallet(String.downcase(address), threshold, min_shared, limit, opts)

      true ->
        Mix.shell().error("Error: wallet address or --market is required")
        Mix.shell().info("Usage: mix polymarket.find_ring <wallet_address> [options]")
        Mix.shell().info("       mix polymarket.find_ring --market <condition_id> [options]")
    end
  end

  defp find_ring_from_wallet(address, threshold, min_shared, limit, opts) do
    # Get seed wallet profile
    profile = Polymarket.build_wallet_profile(address)

    if profile.total_trades == 0 do
      Mix.shell().error("No trades found for wallet: #{address}")
      return_early()
    else
      # Find the ring
      ring = detect_ring(address, threshold, min_shared, limit)

      if opts[:json] do
        output_json(address, profile, ring)
      else
        output_formatted(address, profile, ring, opts[:verbose] || false)
      end
    end
  end

  defp find_ring_from_market(condition_id, threshold, min_shared, limit, opts) do
    # Find top suspicious wallet in this market
    top_wallet = Repo.one(from t in Trade,
      join: m in Market, on: m.id == t.market_id,
      join: ts in TradeScore, on: ts.trade_id == t.id,
      where: m.condition_id == ^condition_id or ilike(m.condition_id, ^"#{condition_id}%"),
      group_by: t.wallet_address,
      order_by: [desc: avg(ts.anomaly_score)],
      limit: 1,
      select: t.wallet_address
    )

    if top_wallet do
      Mix.shell().info("Using top suspicious wallet from market as seed: #{format_wallet(top_wallet)}")
      Mix.shell().info("")
      find_ring_from_wallet(top_wallet, threshold, min_shared, limit, opts)
    else
      Mix.shell().error("No trades found for market: #{condition_id}")
    end
  end

  defp detect_ring(seed_address, threshold, min_shared, limit) do
    # Step 1: Get all markets the seed wallet traded
    seed_markets = Repo.all(from t in Trade,
      where: t.wallet_address == ^seed_address,
      select: %{
        market_id: t.market_id,
        outcome_index: t.outcome_index,
        side: t.side
      }
    )

    market_ids = seed_markets |> Enum.map(& &1.market_id) |> Enum.uniq()

    if length(market_ids) == 0 do
      []
    else
      # Step 2: Find all wallets that traded these markets
      candidates = Repo.all(from t in Trade,
        join: ts in TradeScore, on: ts.trade_id == t.id,
        where: t.market_id in ^market_ids and t.wallet_address != ^seed_address,
        group_by: t.wallet_address,
        having: count(fragment("DISTINCT ?", t.market_id)) >= ^min_shared,
        select: %{
          wallet_address: t.wallet_address,
          shared_markets: count(fragment("DISTINCT ?", t.market_id)),
          trade_count: count(t.id),
          avg_score: avg(ts.anomaly_score),
          wins: count(fragment("CASE WHEN ? = true THEN 1 END", t.was_correct)),
          resolved: count(fragment("CASE WHEN ? IS NOT NULL THEN 1 END", t.was_correct)),
          total_size: sum(t.size)
        }
      )

      # Step 3: Calculate similarity scores for each candidate
      seed_info = get_wallet_market_positions(seed_address, market_ids)

      candidates
      |> Enum.map(fn candidate ->
        candidate_info = get_wallet_market_positions(candidate.wallet_address, market_ids)
        similarity = calculate_similarity(seed_info, candidate_info, candidate)

        Map.put(candidate, :similarity, similarity)
      end)
      |> Enum.filter(fn c -> c.similarity >= threshold end)
      |> Enum.sort_by(& &1.similarity, :desc)
      |> Enum.take(limit)
    end
  end

  defp get_wallet_market_positions(address, market_ids) do
    Repo.all(from t in Trade,
      where: t.wallet_address == ^address and t.market_id in ^market_ids,
      select: %{
        market_id: t.market_id,
        outcome_index: t.outcome_index,
        side: t.side,
        was_correct: t.was_correct
      }
    )
    |> Enum.group_by(& &1.market_id)
    |> Enum.map(fn {market_id, trades} ->
      # Get dominant position in each market
      dominant_outcome = trades
        |> Enum.map(& &1.outcome_index)
        |> Enum.frequencies()
        |> Enum.max_by(fn {_k, v} -> v end, fn -> {0, 0} end)
        |> elem(0)

      dominant_side = trades
        |> Enum.map(& &1.side)
        |> Enum.frequencies()
        |> Enum.max_by(fn {_k, v} -> v end, fn -> {"BUY", 0} end)
        |> elem(0)

      wins = Enum.count(trades, & &1.was_correct == true)
      resolved = Enum.count(trades, & &1.was_correct != nil)

      {market_id, %{
        outcome: dominant_outcome,
        side: dominant_side,
        win_rate: if(resolved > 0, do: wins / resolved, else: nil)
      }}
    end)
    |> Map.new()
  end

  defp calculate_similarity(seed_positions, candidate_positions, candidate) do
    # Only compare markets both traded
    shared_markets = MapSet.intersection(
      MapSet.new(Map.keys(seed_positions)),
      MapSet.new(Map.keys(candidate_positions))
    )

    shared_count = MapSet.size(shared_markets)

    if shared_count == 0 do
      0.0
    else
      # Factor 1: Shared markets ratio (40%)
      seed_market_count = map_size(seed_positions)
      shared_ratio = shared_count / seed_market_count

      # Factor 2: Same-side trading ratio (30%)
      same_side_count = shared_markets
        |> Enum.count(fn market_id ->
          seed = seed_positions[market_id]
          cand = candidate_positions[market_id]
          seed && cand && seed.outcome == cand.outcome && seed.side == cand.side
        end)
      same_side_ratio = same_side_count / shared_count

      # Factor 3: Win rate similarity (20%)
      seed_win_rate = seed_positions
        |> Map.values()
        |> Enum.filter(& &1.win_rate)
        |> Enum.map(& &1.win_rate)
        |> average_or_zero()

      candidate_win_rate = if candidate.resolved > 0 do
        candidate.wins / candidate.resolved
      else
        0.5  # Neutral if no resolved trades
      end

      win_rate_similarity = 1.0 - abs(seed_win_rate - candidate_win_rate)

      # Factor 4: Score similarity (10%)
      avg_score = ensure_float(candidate.avg_score)
      score_factor = min(avg_score, 1.0)  # Higher scores = more suspicious = higher similarity

      # Calculate weighted similarity
      similarity =
        shared_ratio * 0.4 +
        same_side_ratio * 0.3 +
        win_rate_similarity * 0.2 +
        score_factor * 0.1

      Float.round(similarity, 3)
    end
  end

  defp average_or_zero([]), do: 0.5
  defp average_or_zero(list), do: Enum.sum(list) / length(list)

  defp output_formatted(address, profile, ring, verbose) do
    print_header()
    print_seed_info(address, profile)
    print_ring_members(ring, verbose)
    print_ring_statistics(ring, address, profile)
    print_footer(address)
  end

  defp print_header do
    Mix.shell().info("")
    Mix.shell().info("RING DETECTION")
    Mix.shell().info(String.duplicate("═", 65))
    Mix.shell().info("")
  end

  defp print_seed_info(address, profile) do
    short = format_wallet(address)

    Mix.shell().info("SEED WALLET: #{short}")
    Mix.shell().info("├─ Full Address:  #{address}")
    Mix.shell().info("├─ Markets Traded: #{profile.unique_markets}")
    Mix.shell().info("├─ Total Trades:   #{profile.total_trades}")

    win_rate_str = if profile.win_rate do
      "#{Float.round(profile.win_rate * 100, 1)}%"
    else
      "N/A"
    end
    Mix.shell().info("└─ Win Rate:       #{win_rate_str}")
    Mix.shell().info("")
  end

  defp print_ring_members(ring, verbose) do
    if length(ring) == 0 do
      Mix.shell().info("DETECTED RING")
      Mix.shell().info("└─ No ring members found matching criteria")
      Mix.shell().info("")
    else
      Mix.shell().info("DETECTED RING (#{length(ring)} members)")

      ring
      |> Enum.with_index()
      |> Enum.each(fn {member, idx} ->
        prefix = if idx == length(ring) - 1, do: "└─", else: "├─"
        short = format_wallet(member.wallet_address)

        win_str = if member.resolved > 0 do
          rate = member.wins / member.resolved * 100
          "#{round(rate)}% win"
        else
          "unresolved"
        end

        volume = decimal_to_int(member.total_size)
        avg = ensure_float(member.avg_score)

        Mix.shell().info("#{prefix} #{short} - sim: #{member.similarity}, #{member.shared_markets} shared, #{win_str}")

        if verbose do
          Mix.shell().info("   trades: #{member.trade_count}, volume: $#{format_number(volume)}, avg score: #{Float.round(avg, 2)}")
        end
      end)

      Mix.shell().info("")
    end
  end

  defp print_ring_statistics(ring, seed_address, seed_profile) do
    if length(ring) > 0 do
      total_members = length(ring) + 1  # Include seed
      total_trades = Enum.sum(Enum.map(ring, & &1.trade_count)) + seed_profile.total_trades
      ring_volume = Enum.sum(Enum.map(ring, &decimal_to_int(&1.total_size)))
      # Include seed's volume (avg_trade_size * total_trades)
      seed_volume = round(seed_profile.avg_trade_size * seed_profile.total_trades)
      total_volume = ring_volume + seed_volume
      total_wins = Enum.sum(Enum.map(ring, & &1.wins)) + seed_profile.wins
      total_resolved = Enum.sum(Enum.map(ring, & &1.resolved)) + seed_profile.resolved_trades

      aggregate_win_rate = if total_resolved > 0 do
        total_wins / total_resolved * 100
      else
        0
      end

      # Find primary markets (most traded by ring)
      primary_markets = get_ring_primary_markets(seed_address, ring)

      Mix.shell().info("RING STATISTICS (including seed)")
      Mix.shell().info("├─ Total Members:      #{total_members}")
      Mix.shell().info("├─ Total Trades:       #{format_number(total_trades)}")
      Mix.shell().info("├─ Aggregate Win Rate: #{Float.round(aggregate_win_rate, 1)}%")
      Mix.shell().info("├─ Total Volume:       $#{format_number(total_volume)}")
      Mix.shell().info("└─ Primary Markets:    #{primary_markets}")
      Mix.shell().info("")
    end
  end

  defp get_ring_primary_markets(seed_address, ring) do
    all_addresses = [seed_address | Enum.map(ring, & &1.wallet_address)]

    # Get top markets by trade count
    markets = Repo.all(from t in Trade,
      join: m in Market, on: m.id == t.market_id,
      where: t.wallet_address in ^all_addresses,
      group_by: [m.id, m.question],
      order_by: [desc: count(t.id)],
      limit: 3,
      select: %{
        question: m.question,
        trade_count: count(t.id)
      }
    )

    markets
    |> Enum.map(fn m -> truncate(m.question || "Unknown", 30) end)
    |> Enum.join(", ")
  end

  defp print_footer(address) do
    Mix.shell().info(String.duplicate("─", 65))
    Mix.shell().info("Next steps:")
    Mix.shell().info("  • Investigate member: mix polymarket.investigate_wallet <address>")
    Mix.shell().info("  • Export for analysis: mix polymarket.find_ring #{String.slice(address, 0, 12)}... --json")
    Mix.shell().info("")
  end

  defp output_json(address, profile, ring) do
    json = %{
      seed: %{
        address: address,
        profile: profile
      },
      ring_members: Enum.map(ring, fn m ->
        %{
          address: m.wallet_address,
          similarity: m.similarity,
          shared_markets: m.shared_markets,
          trade_count: m.trade_count,
          win_rate: if(m.resolved > 0, do: m.wins / m.resolved, else: nil),
          avg_score: ensure_float(m.avg_score),
          total_volume: decimal_to_int(m.total_size)
        }
      end),
      statistics: %{
        total_members: length(ring) + 1,
        total_trades: Enum.sum(Enum.map(ring, & &1.trade_count)) + profile.total_trades
      }
    }

    Mix.shell().info(Jason.encode!(json, pretty: true))
  end

  defp return_early, do: :ok

  # Formatting helpers
  defp format_wallet(nil), do: "Unknown"
  defp format_wallet(address) when byte_size(address) > 10 do
    "#{String.slice(address, 0, 6)}...#{String.slice(address, -4, 4)}"
  end
  defp format_wallet(address), do: address

  defp format_number(n) when is_integer(n) do
    n
    |> Integer.to_string()
    |> String.reverse()
    |> String.replace(~r/(\d{3})(?=\d)/, "\\1,")
    |> String.reverse()
  end
  defp format_number(n) when is_float(n), do: format_number(round(n))
  defp format_number(nil), do: "0"
  defp format_number(n), do: "#{n}"

  defp truncate(nil, _), do: ""
  defp truncate(str, max) when is_binary(str) do
    if String.length(str) > max do
      String.slice(str, 0, max) <> "..."
    else
      str
    end
  end

  defp ensure_float(nil), do: 0.0
  defp ensure_float(%Decimal{} = d), do: Decimal.to_float(d)
  defp ensure_float(f) when is_float(f), do: f
  defp ensure_float(n) when is_integer(n), do: n * 1.0

  defp decimal_to_int(nil), do: 0
  defp decimal_to_int(%Decimal{} = d), do: Decimal.to_integer(Decimal.round(d, 0))
  defp decimal_to_int(n) when is_number(n), do: round(n)
end
