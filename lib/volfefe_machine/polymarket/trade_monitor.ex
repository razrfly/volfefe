defmodule VolfefeMachine.Polymarket.TradeMonitor do
  @moduledoc """
  **DEPRECATED**: This module is deprecated and will be removed.

  Use Oban workers instead:
  - `VolfefeMachine.Workers.Polymarket.TradeIngestionWorker` - Trade ingestion
  - `VolfefeMachine.Workers.Polymarket.TradeScoringWorker` - Trade scoring
  - `VolfefeMachine.Workers.Polymarket.AlertingWorker` - Alert creation/notification

  See Issue #194 for removal timeline.

  ---

  GenServer for real-time trade monitoring and alert generation.

  Polls the Polymarket API for new trades, scores them against baselines,
  and generates alerts when suspicious patterns are detected.

  ## Architecture

  ```
  ┌─────────────────────────────────────────────────────────────────┐
  │                    REAL-TIME MONITORING                         │
  ├─────────────────────────────────────────────────────────────────┤
  │  Poll API  →  Score Trade  →  Check Patterns  →  Generate Alert │
  │  (30s)        (z-scores)     (match rules)      (if suspicious) │
  └─────────────────────────────────────────────────────────────────┘
  ```

  ## Configuration

  The monitor can be configured via application config:

      config :volfefe_machine, VolfefeMachine.Polymarket.TradeMonitor,
        poll_interval: 30_000,           # 30 seconds
        anomaly_threshold: 0.7,          # Minimum anomaly score to alert
        probability_threshold: 0.5,      # Minimum insider probability
        enabled: true                    # Whether monitoring is active

  ## Usage

      # Start the monitor (usually via supervision tree)
      {:ok, pid} = TradeMonitor.start_link()

      # Check monitor status
      TradeMonitor.status()

      # Manually trigger a poll
      TradeMonitor.poll_now()

      # Enable/disable monitoring
      TradeMonitor.enable()
      TradeMonitor.disable()

      # Update thresholds at runtime
      TradeMonitor.set_thresholds(anomaly: 0.8, probability: 0.6)
  """

  use GenServer
  require Logger

  alias VolfefeMachine.Polymarket
  alias VolfefeMachine.Polymarket.{Alert, Trade, TradeScore, Market, Notifier}
  alias VolfefeMachine.Repo

  import Ecto.Query

  @default_poll_interval 30_000  # 30 seconds
  @default_anomaly_threshold 0.7
  @default_probability_threshold 0.5

  # ============================================
  # Client API
  # ============================================

  def start_link(opts \\ []) do
    GenServer.start_link(__MODULE__, opts, name: __MODULE__)
  end

  @doc """
  Get current monitor status.
  """
  def status do
    GenServer.call(__MODULE__, :status)
  end

  @doc """
  Manually trigger a poll cycle.
  """
  def poll_now do
    GenServer.cast(__MODULE__, :poll_now)
  end

  @doc """
  Enable monitoring.
  """
  def enable do
    GenServer.call(__MODULE__, :enable)
  end

  @doc """
  Disable monitoring.
  """
  def disable do
    GenServer.call(__MODULE__, :disable)
  end

  @doc """
  Update alert thresholds at runtime.
  """
  def set_thresholds(opts) do
    GenServer.call(__MODULE__, {:set_thresholds, opts})
  end

  @doc """
  Get recent alerts.
  """
  def recent_alerts(limit \\ 10) do
    GenServer.call(__MODULE__, {:recent_alerts, limit})
  end

  # ============================================
  # Server Callbacks
  # ============================================

  @impl true
  def init(opts) do
    poll_interval = Keyword.get(opts, :poll_interval, @default_poll_interval)
    anomaly_threshold = Keyword.get(opts, :anomaly_threshold, @default_anomaly_threshold)
    probability_threshold = Keyword.get(opts, :probability_threshold, @default_probability_threshold)
    enabled = Keyword.get(opts, :enabled, true)

    state = %{
      poll_interval: poll_interval,
      anomaly_threshold: anomaly_threshold,
      probability_threshold: probability_threshold,
      enabled: enabled,
      last_poll_at: nil,
      last_trade_timestamp: get_latest_trade_timestamp(),
      trades_processed: 0,
      alerts_generated: 0,
      errors: 0
    }

    # Schedule first poll if enabled
    if enabled do
      schedule_poll(poll_interval)
    end

    Logger.info("TradeMonitor started: poll_interval=#{poll_interval}ms, enabled=#{enabled}")

    {:ok, state}
  end

  @impl true
  def handle_call(:status, _from, state) do
    status = %{
      enabled: state.enabled,
      poll_interval: state.poll_interval,
      thresholds: %{
        anomaly: state.anomaly_threshold,
        probability: state.probability_threshold
      },
      stats: %{
        last_poll_at: state.last_poll_at,
        trades_processed: state.trades_processed,
        alerts_generated: state.alerts_generated,
        errors: state.errors
      }
    }

    {:reply, status, state}
  end

  @impl true
  def handle_call(:enable, _from, state) do
    if not state.enabled do
      schedule_poll(state.poll_interval)
    end

    {:reply, :ok, %{state | enabled: true}}
  end

  @impl true
  def handle_call(:disable, _from, state) do
    {:reply, :ok, %{state | enabled: false}}
  end

  @impl true
  def handle_call({:set_thresholds, opts}, _from, state) do
    new_state = %{state |
      anomaly_threshold: Keyword.get(opts, :anomaly, state.anomaly_threshold),
      probability_threshold: Keyword.get(opts, :probability, state.probability_threshold)
    }

    {:reply, :ok, new_state}
  end

  @impl true
  def handle_call({:recent_alerts, limit}, _from, state) do
    alerts = from(a in Alert,
      order_by: [desc: a.triggered_at],
      limit: ^limit
    ) |> Repo.all()

    {:reply, alerts, state}
  end

  @impl true
  def handle_cast(:poll_now, state) do
    new_state = do_poll(state)
    {:noreply, new_state}
  end

  @impl true
  def handle_info(:poll, state) do
    new_state = if state.enabled do
      do_poll(state)
    else
      state
    end

    # Schedule next poll if enabled
    if new_state.enabled do
      schedule_poll(new_state.poll_interval)
    end

    {:noreply, new_state}
  end

  # ============================================
  # Private Functions
  # ============================================

  defp schedule_poll(interval) do
    Process.send_after(self(), :poll, interval)
  end

  defp do_poll(state) do
    Logger.debug("TradeMonitor: Starting poll cycle")

    try do
      # Fetch recent trades from API
      {:ok, trades} = fetch_recent_trades(state.last_trade_timestamp)

      Logger.debug("TradeMonitor: Fetched #{length(trades)} new trades")

      # Process each trade
      {processed, alerts} = process_trades(trades, state)

      # Update last trade timestamp
      latest_timestamp = get_latest_timestamp(trades, state.last_trade_timestamp)

      %{state |
        last_poll_at: DateTime.utc_now(),
        last_trade_timestamp: latest_timestamp,
        trades_processed: state.trades_processed + processed,
        alerts_generated: state.alerts_generated + alerts
      }
    rescue
      e ->
        Logger.error("TradeMonitor poll error: #{inspect(e)}")
        %{state | errors: state.errors + 1}
    end
  end

  defp fetch_recent_trades(since_timestamp) do
    # Fetch trades newer than our last seen timestamp
    # This would call the Polymarket API in production
    # For now, we'll query our local database for demonstration

    query = from(t in Trade,
      left_join: ts in TradeScore, on: ts.trade_id == t.id,
      where: is_nil(ts.id),  # Only unscored trades
      order_by: [desc: t.trade_timestamp],
      limit: 100
    )

    query = if since_timestamp do
      from(t in query, where: t.trade_timestamp > ^since_timestamp)
    else
      query
    end

    trades = Repo.all(query)
    {:ok, trades}
  end

  defp process_trades(trades, state) do
    results = Enum.map(trades, fn trade ->
      process_single_trade(trade, state)
    end)

    processed = Enum.count(results, &match?({:ok, _}, &1))
    alerts = Enum.count(results, fn
      {:ok, :alert_generated} -> true
      _ -> false
    end)

    {processed, alerts}
  end

  defp process_single_trade(trade, state) do
    # Score the trade
    case Polymarket.score_trade(trade) do
      {:ok, score} ->
        # Check if it meets alert thresholds
        if should_alert?(score, state) do
          generate_alert(trade, score, state)
          {:ok, :alert_generated}
        else
          {:ok, :no_alert}
        end

      {:error, reason} ->
        Logger.warning("Failed to score trade #{trade.id}: #{inspect(reason)}")
        {:error, reason}
    end
  end

  defp should_alert?(score, state) do
    anomaly = ensure_float(score.anomaly_score)
    probability = ensure_float(score.insider_probability)

    anomaly >= state.anomaly_threshold or probability >= state.probability_threshold
  end

  defp generate_alert(trade, score, _state) do
    Logger.info("Generating alert for trade #{trade.id}")

    # Get market info
    market = if trade.market_id, do: Repo.get(Market, trade.market_id)

    # Determine alert type based on triggers
    triggers = determine_triggers(score)
    alert_type = Alert.determine_alert_type(triggers)
    severity = Alert.calculate_severity(score.insider_probability, score.anomaly_score)

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
      market_question: market && market.question,
      trade_size: trade.size,
      trade_outcome: trade.outcome,
      trade_price: trade.price,
      matched_patterns: score.matched_patterns,
      highest_pattern_score: score.highest_pattern_score,
      triggered_at: DateTime.utc_now(),
      trade_timestamp: trade.trade_timestamp
    }

    case %Alert{} |> Alert.changeset(attrs) |> Repo.insert() do
      {:ok, alert} ->
        Logger.info("Alert created: #{alert.alert_id} (#{severity})")
        broadcast_alert(alert)
        {:ok, alert}

      {:error, changeset} ->
        Logger.error("Failed to create alert: #{inspect(changeset.errors)}")
        {:error, changeset}
    end
  end

  defp determine_triggers(score) do
    triggers = []

    triggers = if ensure_float(score.anomaly_score) >= 0.7, do: ["anomaly" | triggers], else: triggers
    triggers = if score.matched_patterns && map_size(score.matched_patterns) > 0, do: ["pattern" | triggers], else: triggers
    triggers = if ensure_float(score.size_zscore) >= 3.0, do: ["whale" | triggers], else: triggers
    triggers = if ensure_float(score.timing_zscore) >= 2.5, do: ["timing" | triggers], else: triggers

    triggers
  end

  defp broadcast_alert(alert) do
    # Log the alert
    Logger.info("""
    [ALERT] #{alert.severity |> String.upcase()}
    Type: #{alert.alert_type}
    Wallet: #{alert.wallet_address}
    Score: #{alert.insider_probability}
    Market: #{alert.market_question || "Unknown"}
    """)

    # Broadcast via PubSub for LiveView updates
    Phoenix.PubSub.broadcast(
      VolfefeMachine.PubSub,
      "polymarket:alerts",
      {:new_alert, alert}
    )

    # Send external notifications (Slack, Discord, etc.)
    spawn(fn ->
      case Notifier.notify(alert) do
        results when is_map(results) ->
          Enum.each(results, fn
            {channel, {:ok, :sent}} ->
              Logger.debug("Notification sent to #{channel}")
            {channel, {:skipped, reason}} ->
              Logger.debug("Notification skipped for #{channel}: #{reason}")
            {channel, {:error, reason}} ->
              Logger.warning("Notification failed for #{channel}: #{inspect(reason)}")
          end)
        _ ->
          :ok
      end
    end)
  end

  defp get_latest_trade_timestamp do
    from(t in Trade,
      order_by: [desc: t.trade_timestamp],
      limit: 1,
      select: t.trade_timestamp
    )
    |> Repo.one()
  end

  defp get_latest_timestamp([], current), do: current
  defp get_latest_timestamp(trades, _current) do
    trades
    |> Enum.map(& &1.trade_timestamp)
    |> Enum.max(DateTime)
  end

  defp ensure_float(%Decimal{} = d), do: Decimal.to_float(d)
  defp ensure_float(n) when is_float(n), do: n
  defp ensure_float(n) when is_integer(n), do: n * 1.0
  defp ensure_float(nil), do: 0.0
end
