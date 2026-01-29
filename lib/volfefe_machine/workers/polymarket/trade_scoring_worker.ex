defmodule VolfefeMachine.Workers.Polymarket.TradeScoringWorker do
  @moduledoc """
  Oban worker for scoring unscored trades after ingestion.

  Runs automatically after TradeIngestionWorker or on a scheduled interval
  to ensure all trades have rule-based anomaly scores.

  ## Scheduling

  Can be triggered:
  1. Automatically after TradeIngestionWorker completes
  2. Via cron schedule as backup (every 5 minutes)
  3. Manually for specific markets

  ## Manual Execution

      # Score all unscored trades
      %{}
      |> VolfefeMachine.Workers.Polymarket.TradeScoringWorker.new()
      |> Oban.insert()

      # Score specific market
      %{condition_id: "0x123..."}
      |> VolfefeMachine.Workers.Polymarket.TradeScoringWorker.new()
      |> Oban.insert()

  ## Job Arguments

    * `:limit` - Maximum trades to score (optional, default: 1000)
    * `:condition_id` - Score trades for specific market only
    * `:trigger_alerting` - Enqueue AlertingWorker after scoring (default: true)
  """

  use Oban.Worker,
    queue: :polymarket,
    max_attempts: 3,
    unique: [period: 120]  # Prevent duplicate jobs within 2 minutes

  require Logger
  import Ecto.Query

  alias VolfefeMachine.Repo
  alias VolfefeMachine.Polymarket
  alias VolfefeMachine.Polymarket.{Trade, TradeScore}

  @default_limit 1000

  @impl Oban.Worker
  def perform(%Oban.Job{args: args}) do
    limit = Map.get(args, "limit", @default_limit)
    condition_id = Map.get(args, "condition_id")
    trigger_alerting = Map.get(args, "trigger_alerting", true)

    Logger.info("[TradeScoringWorker] Starting: limit=#{limit}, condition_id=#{inspect(condition_id)}")

    # Find unscored trades
    unscored_trades = find_unscored_trades(limit, condition_id)

    if length(unscored_trades) == 0 do
      Logger.info("[TradeScoringWorker] No unscored trades found")
      {:ok, %{scored: 0, errors: 0}}
    else
      Logger.info("[TradeScoringWorker] Found #{length(unscored_trades)} unscored trades")

      # Score each trade
      results = Enum.map(unscored_trades, fn trade ->
        case Polymarket.score_trade(trade) do
          {:ok, _score} -> :ok
          {:error, reason} ->
            Logger.warning("[TradeScoringWorker] Failed to score trade #{trade.id}: #{inspect(reason)}")
            :error
        end
      end)

      scored = Enum.count(results, &(&1 == :ok))
      errors = Enum.count(results, &(&1 == :error))

      Logger.info("[TradeScoringWorker] Complete: scored=#{scored}, errors=#{errors}")

      # Trigger alerting worker if enabled
      if trigger_alerting and scored > 0 do
        enqueue_alerting_worker()
      end

      {:ok, %{
        scored: scored,
        errors: errors,
        completed_at: DateTime.utc_now() |> DateTime.to_iso8601()
      }}
    end
  end

  @doc """
  Find trades that don't have scores yet.
  """
  def find_unscored_trades(limit, condition_id \\ nil) do
    # Trades without scores
    base_query = from(t in Trade,
      left_join: ts in TradeScore, on: ts.trade_id == t.id,
      where: is_nil(ts.id),
      order_by: [desc: t.inserted_at],
      limit: ^limit,
      preload: [:market, :wallet]
    )

    # Optionally filter by condition_id
    query = if condition_id do
      from(t in base_query, where: t.condition_id == ^condition_id)
    else
      base_query
    end

    Repo.all(query)
  end

  defp enqueue_alerting_worker do
    case %{}
         |> VolfefeMachine.Workers.Polymarket.AlertingWorker.new()
         |> Oban.insert() do
      {:ok, _job} ->
        Logger.debug("[TradeScoringWorker] Enqueued AlertingWorker")
      {:error, reason} ->
        Logger.warning("[TradeScoringWorker] Failed to enqueue AlertingWorker: #{inspect(reason)}")
    end
  end
end
