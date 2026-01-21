defmodule VolfefeMachine.Workers.Polymarket.DiversityCheckWorker do
  @moduledoc """
  Oban worker for periodic coverage diversity checks.

  Monitors trade ingestion coverage across categories and
  logs alerts when issues are detected (stale categories,
  high concentration, missing coverage).

  ## Scheduling

  This worker is scheduled via Oban.Plugins.Cron to run every 30 minutes.
  See config/config.exs for cron configuration.

  ## Manual Execution

      # Run diversity check now
      %{}
      |> VolfefeMachine.Workers.Polymarket.DiversityCheckWorker.new()
      |> Oban.insert()

  ## Job Arguments

    * None required - runs full diversity check
  """

  use Oban.Worker,
    queue: :polymarket,
    max_attempts: 2,
    unique: [period: 600]  # Prevent duplicate jobs within 10 minutes

  require Logger
  alias VolfefeMachine.Polymarket.DiversityMonitor

  @impl Oban.Worker
  def perform(%Oban.Job{}) do
    Logger.info("[DiversityCheck] Starting coverage diversity check")

    result = DiversityMonitor.run_check()

    Logger.info("[DiversityCheck] Complete: health_score=#{result.health_score}, alerts=#{length(result.alerts)}")

    {:ok, %{
      health_score: result.health_score,
      categories_active: result.categories_active,
      total_trades: result.total_trades,
      concentration_pct: result.concentration,
      alert_count: length(result.alerts),
      alerts: Enum.map(result.alerts, & &1.message),
      completed_at: DateTime.utc_now() |> DateTime.to_iso8601()
    }}
  end
end
