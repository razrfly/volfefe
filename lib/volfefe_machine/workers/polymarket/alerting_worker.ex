defmodule VolfefeMachine.Workers.Polymarket.AlertingWorker do
  @moduledoc """
  Oban worker for creating and dispatching insider trading alerts.

  Scans for high-scoring trades that don't have alerts yet,
  creates alerts, and sends notifications via configured channels.

  ## Alert Thresholds (configurable)

  - Critical: ensemble_score > 0.9
  - High: ensemble_score > 0.7
  - Medium: ensemble_score > 0.5

  Default: Only create alerts for High+ (ensemble_score > 0.7)

  ## Scheduling

  Can be triggered:
  1. Automatically after TradeScoringWorker completes
  2. Via cron schedule (every 10 minutes)
  3. Manually

  ## Configuration

      config :volfefe_machine, VolfefeMachine.Workers.Polymarket.AlertingWorker,
        min_ensemble_score: 0.7,  # Only alert on High+ scores
        enabled: true,
        notify: true  # Send notifications

  ## Manual Execution

      # Check for new alerts
      %{}
      |> VolfefeMachine.Workers.Polymarket.AlertingWorker.new()
      |> Oban.insert()
  """

  use Oban.Worker,
    queue: :polymarket,
    max_attempts: 3,
    unique: [period: 300]  # Prevent duplicate jobs within 5 minutes

  require Logger
  import Ecto.Query

  alias VolfefeMachine.Repo
  alias VolfefeMachine.Polymarket.{Alert, Trade, TradeScore, Market, Notifier}

  @default_min_score 0.7  # High tier threshold

  @impl Oban.Worker
  def perform(%Oban.Job{args: args}) do
    if enabled?() do
      min_score = Map.get(args, "min_ensemble_score", config_min_score())
      notify = Map.get(args, "notify", config_notify())
      limit = Map.get(args, "limit", 100)

      Logger.info("[AlertingWorker] Starting: min_score=#{min_score}, notify=#{notify}")

      # Find high-scoring trades without alerts
      candidates = find_alert_candidates(min_score, limit)

      if length(candidates) == 0 do
        Logger.info("[AlertingWorker] No new alert candidates found")
        {:ok, %{alerts_created: 0, notifications_sent: 0}}
      else
        Logger.info("[AlertingWorker] Found #{length(candidates)} alert candidates")

        # Create alerts and optionally send notifications
        results = Enum.map(candidates, fn {trade, score} ->
          case create_alert(trade, score) do
            {:ok, alert} ->
              notification_result = if notify do
                send_notification(alert)
              else
                {:skipped, :notifications_disabled}
              end
              {:ok, alert, notification_result}

            {:error, reason} ->
              Logger.warning("[AlertingWorker] Failed to create alert for trade #{trade.id}: #{inspect(reason)}")
              {:error, reason}
          end
        end)

        alerts_created = Enum.count(results, &match?({:ok, _, _}, &1))
        notifications_sent = Enum.count(results, fn
          {:ok, _, %{slack: {:ok, _}}} -> true
          {:ok, _, %{discord: {:ok, _}}} -> true
          _ -> false
        end)

        Logger.info("[AlertingWorker] Complete: alerts=#{alerts_created}, notifications=#{notifications_sent}")

        {:ok, %{
          alerts_created: alerts_created,
          notifications_sent: notifications_sent,
          completed_at: DateTime.utc_now() |> DateTime.to_iso8601()
        }}
      end
    else
      Logger.info("[AlertingWorker] Alerting disabled, skipping")
      {:ok, %{skipped: true, reason: :disabled}}
    end
  end

  @doc """
  Find high-scoring trades that don't have alerts yet.
  """
  def find_alert_candidates(min_score, limit \\ 100) do
    # Defensively normalize min_score to Decimal (handles floats, integers, strings)
    min_score_decimal =
      cond do
        is_float(min_score) -> Decimal.from_float(min_score)
        is_integer(min_score) -> Decimal.new(min_score)
        is_binary(min_score) -> Decimal.new(min_score)
        true -> Decimal.new(min_score)
      end

    query = from(ts in TradeScore,
      join: t in Trade, on: t.id == ts.trade_id,
      left_join: a in Alert, on: a.trade_id == t.id,
      left_join: m in Market, on: m.id == t.market_id,
      where: is_nil(a.id),  # No existing alert
      where: ts.ensemble_score > ^min_score_decimal,  # Above threshold
      order_by: [desc: ts.ensemble_score],
      limit: ^limit,
      select: {t, ts, m}
    )

    Repo.all(query)
    |> Enum.map(fn {trade, score, market} ->
      # Attach market to trade for convenience
      trade = %{trade | market: market}
      {trade, score}
    end)
  end

  @doc """
  Create an alert for a high-scoring trade.
  """
  def create_alert(%Trade{} = trade, %TradeScore{} = score) do
    severity = determine_severity(score.ensemble_score)
    alert_type = determine_alert_type(score)

    attrs = %{
      alert_id: Alert.generate_alert_id(trade.id),
      alert_type: alert_type,
      trade_id: trade.id,
      trade_score_id: score.id,
      market_id: trade.market_id,
      transaction_hash: trade.transaction_hash,
      wallet_address: trade.wallet_address,
      condition_id: trade.condition_id,
      severity: severity,
      anomaly_score: score.anomaly_score,
      insider_probability: score.insider_probability,
      market_question: trade.market && trade.market.question,
      trade_size: trade.size,
      trade_outcome: trade.outcome,
      trade_price: trade.price,
      matched_patterns: score.matched_patterns,
      highest_pattern_score: score.highest_pattern_score,
      triggered_at: DateTime.utc_now(),
      trade_timestamp: trade.trade_timestamp
    }

    %Alert{}
    |> Alert.changeset(attrs)
    |> Repo.insert()
  end

  @doc """
  Send notification for an alert via configured channels.
  """
  def send_notification(%Alert{} = alert) do
    Notifier.notify(alert)
  end

  # ============================================
  # Private Helpers
  # ============================================

  defp determine_severity(ensemble_score) do
    score = ensure_float(ensemble_score)
    cond do
      score > 0.9 -> "critical"
      score > 0.7 -> "high"
      score > 0.5 -> "medium"
      true -> "low"
    end
  end

  defp determine_alert_type(%TradeScore{} = score) do
    triggers = []

    triggers = if score.trinity_pattern, do: ["trinity" | triggers], else: triggers
    triggers = if ensure_float(score.highest_pattern_score) > 0.7, do: ["pattern" | triggers], else: triggers
    triggers = if ensure_float(score.anomaly_score) > 0.7, do: ["anomaly" | triggers], else: triggers

    case triggers do
      [] -> "anomaly_threshold"
      [single] -> alert_type_for_trigger(single)
      _multiple -> "combined"
    end
  end

  defp alert_type_for_trigger("trinity"), do: "combined"
  defp alert_type_for_trigger("pattern"), do: "pattern_match"
  defp alert_type_for_trigger("anomaly"), do: "anomaly_threshold"
  defp alert_type_for_trigger(_), do: "anomaly_threshold"

  defp ensure_float(%Decimal{} = d), do: Decimal.to_float(d)
  defp ensure_float(n) when is_float(n), do: n
  defp ensure_float(n) when is_integer(n), do: n * 1.0
  defp ensure_float(nil), do: 0.0

  # ============================================
  # Configuration
  # ============================================

  defp config do
    Application.get_env(:volfefe_machine, __MODULE__, [])
  end

  defp enabled? do
    Keyword.get(config(), :enabled, true)
  end

  defp config_min_score do
    Keyword.get(config(), :min_ensemble_score, @default_min_score)
  end

  defp config_notify do
    Keyword.get(config(), :notify, true)
  end
end
