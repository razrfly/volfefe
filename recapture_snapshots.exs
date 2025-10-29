# Capture snapshots for content #129 (negative sentiment)

alias VolfefeMachine.MarketData.Jobs

# Enqueue the snapshot capture job
case Jobs.capture_snapshots(content_id: 129, force: true) do
  {:ok, job} ->
    IO.puts("✅ Successfully enqueued snapshot capture job ##{job.id} for content #129 (negative sentiment)")
    IO.puts("   Published: Oct 26, 2025 at 6:26 PM")
    IO.puts("   Text: \"What's worse, the NBA Players cheating at cards...\"")
    IO.puts("   Job will capture 20 snapshots (5 assets × 4 windows)")

  {:error, reason} ->
    IO.puts("❌ Failed to enqueue job: #{inspect(reason)}")
end
