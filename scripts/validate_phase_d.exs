import Ecto.Query
alias VolfefeMachine.Repo
alias VolfefeMachine.Polymarket.{Market, Trade}

IO.puts("═══════════════════════════════════════════════════════════════")
IO.puts("       PHASE D: PRE-RESOLUTION WINDOW VALIDATION")
IO.puts("═══════════════════════════════════════════════════════════════\n")

# 1. Count resolved markets with end_date AND resolved_outcome
resolved_count = Repo.one(
  from(m in Market,
    where: not is_nil(m.end_date) and not is_nil(m.resolved_outcome),
    select: count(m.id)
  )
)
IO.puts("1. Resolved markets with end_date & outcome: #{resolved_count}")

# 2. Count markets with ANY trades
markets_with_trades = Repo.one(
  from(m in Market,
    where: not is_nil(m.end_date) and not is_nil(m.resolved_outcome),
    join: t in Trade, on: t.market_id == m.id,
    select: count(m.id, :distinct)
  )
)
IO.puts("2. Resolved markets with trades: #{markets_with_trades}")

# 3. Pre-resolution trades (72h window) - use interval
pre_resolution_stats = Repo.one(
  from(t in Trade,
    join: m in Market, on: t.market_id == m.id,
    where: not is_nil(m.end_date) and not is_nil(m.resolved_outcome),
    where: t.trade_timestamp >= fragment("? - interval '72 hours'", m.end_date),
    where: t.trade_timestamp <= m.end_date,
    select: %{
      market_count: count(m.id, :distinct),
      trade_count: count(t.id),
      total_volume: sum(t.usdc_size),
      unique_wallets: count(t.wallet_address, :distinct)
    }
  )
)

IO.puts("")
IO.puts("3. Pre-Resolution Window (72h before end_date):")
IO.puts("   Markets with trades: #{pre_resolution_stats.market_count}")
IO.puts("   Total trades: #{pre_resolution_stats.trade_count}")
IO.puts("   Total volume: $#{Decimal.round(pre_resolution_stats.total_volume || Decimal.new(0), 2)}")
IO.puts("   Unique wallets: #{pre_resolution_stats.unique_wallets}")

# 4. Time window breakdown
IO.puts("")
IO.puts("4. Trade Distribution by Time Window:")

window_0_24 = Repo.one(
  from(t in Trade,
    join: m in Market, on: t.market_id == m.id,
    where: not is_nil(m.end_date) and not is_nil(m.resolved_outcome),
    where: t.trade_timestamp >= fragment("? - interval '24 hours'", m.end_date),
    where: t.trade_timestamp <= m.end_date,
    select: count(t.id)
  )
)
IO.puts("   0-24h before resolution: #{window_0_24} trades")

window_24_48 = Repo.one(
  from(t in Trade,
    join: m in Market, on: t.market_id == m.id,
    where: not is_nil(m.end_date) and not is_nil(m.resolved_outcome),
    where: t.trade_timestamp >= fragment("? - interval '48 hours'", m.end_date),
    where: t.trade_timestamp < fragment("? - interval '24 hours'", m.end_date),
    select: count(t.id)
  )
)
IO.puts("   24-48h before resolution: #{window_24_48} trades")

window_48_72 = Repo.one(
  from(t in Trade,
    join: m in Market, on: t.market_id == m.id,
    where: not is_nil(m.end_date) and not is_nil(m.resolved_outcome),
    where: t.trade_timestamp >= fragment("? - interval '72 hours'", m.end_date),
    where: t.trade_timestamp < fragment("? - interval '48 hours'", m.end_date),
    select: count(t.id)
  )
)
IO.puts("   48-72h before resolution: #{window_48_72} trades")

# 5. Check timing quality
IO.puts("")
IO.puts("5. Timing Data Quality:")
trades_with_timing = Repo.one(
  from(t in Trade,
    join: m in Market, on: t.market_id == m.id,
    where: not is_nil(m.end_date) and not is_nil(m.resolved_outcome),
    where: not is_nil(t.hours_before_resolution),
    select: count(t.id)
  )
)
total_resolved_trades = Repo.one(
  from(t in Trade,
    join: m in Market, on: t.market_id == m.id,
    where: not is_nil(m.end_date) and not is_nil(m.resolved_outcome),
    select: count(t.id)
  )
)
pct = if total_resolved_trades > 0, do: Float.round(trades_with_timing / total_resolved_trades * 100, 1), else: 0.0
IO.puts("   Trades with hours_before_resolution: #{trades_with_timing}/#{total_resolved_trades} (#{pct}%)")

# 6. Check was_correct populated
trades_with_outcome = Repo.one(
  from(t in Trade,
    join: m in Market, on: t.market_id == m.id,
    where: not is_nil(m.end_date) and not is_nil(m.resolved_outcome),
    where: not is_nil(t.was_correct),
    select: count(t.id)
  )
)
pct2 = if total_resolved_trades > 0, do: Float.round(trades_with_outcome / total_resolved_trades * 100.0, 1), else: 0.0
IO.puts("   Trades with was_correct: #{trades_with_outcome}/#{total_resolved_trades} (#{pct2}%)")

IO.puts("")
IO.puts("═══════════════════════════════════════════════════════════════")
IO.puts("")

# Summary
IO.puts("VALIDATION SUMMARY:")
ok1 = markets_with_trades >= 100
IO.puts("  #{if ok1, do: "✅", else: "❌"} ≥100 resolved markets with trades: #{markets_with_trades}")
ok2 = pre_resolution_stats.market_count >= 50
IO.puts("  #{if ok2, do: "✅", else: "⚠️"} Markets with pre-resolution trades: #{pre_resolution_stats.market_count}")
ok3 = pct >= 50
IO.puts("  #{if ok3, do: "✅", else: "⚠️"} Timing data quality: #{pct}%")

if ok1 and ok2 do
  IO.puts("")
  IO.puts("🚀 GREEN LIGHT FOR PHASE 3 - Data sufficient for insider detection!")
else
  IO.puts("")
  IO.puts("⚠️  Additional data may be needed")
end
