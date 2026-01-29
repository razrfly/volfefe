defmodule VolfefeMachine.Workers.Polymarket.PredictionWorker do
  @moduledoc """
  Oban worker for automatically recording forward predictions.

  Scans active markets with suspicious trading patterns and records
  predictions BEFORE market resolution for later validation.

  ## Prediction Strategy

  Predictions are based on suspicious trader consensus:
  - If >50% suspicious volume is on "Yes" → Predict "Yes"
  - If >50% suspicious volume is on "No" → Predict "No"
  - Confidence is the percentage of volume on winning side

  ## Scheduling

  Runs every 6 hours via cron to:
  1. Find active markets with high watchability scores
  2. Record predictions with timestamps
  3. Skip markets that already have recent predictions (24h)

  ## Configuration

      config :volfefe_machine, VolfefeMachine.Workers.Polymarket.PredictionWorker,
        min_watchability: 0.5,  # Minimum watchability score
        max_predictions: 10,     # Max new predictions per run
        enabled: true

  ## Manual Execution

      # Record predictions on suspicious active markets
      %{}
      |> VolfefeMachine.Workers.Polymarket.PredictionWorker.new()
      |> Oban.insert()

      # With custom options
      %{min_watchability: 0.6, max_predictions: 20}
      |> VolfefeMachine.Workers.Polymarket.PredictionWorker.new()
      |> Oban.insert()
  """

  use Oban.Worker,
    queue: :polymarket,
    max_attempts: 3,
    unique: [period: 3600]  # Prevent duplicate jobs within 1 hour

  require Logger

  alias VolfefeMachine.Polymarket
  alias VolfefeMachine.Polymarket.Prediction

  @default_min_watchability 0.5
  @default_max_predictions 10

  @impl Oban.Worker
  def perform(%Oban.Job{args: args}) do
    if enabled?() do
      min_watchability = Map.get(args, "min_watchability", config_min_watchability())
      max_predictions = Map.get(args, "max_predictions", config_max_predictions())

      Logger.info("[PredictionWorker] Starting: min_watchability=#{min_watchability}, max=#{max_predictions}")

      # Find suspicious active markets
      markets = Polymarket.find_markets_for_prediction(min_watchability, limit: max_predictions * 2)

      if length(markets) == 0 do
        Logger.info("[PredictionWorker] No suspicious active markets found above threshold")
        {:ok, %{predictions_recorded: 0, skipped: 0}}
      else
        Logger.info("[PredictionWorker] Found #{length(markets)} candidate markets")

        # Process markets and record predictions
        {recorded, skipped, _results} = process_markets(markets, max_predictions)

        Logger.info("[PredictionWorker] Complete: recorded=#{recorded}, skipped=#{skipped}")

        {:ok, %{
          predictions_recorded: recorded,
          skipped: skipped,
          completed_at: DateTime.utc_now() |> DateTime.to_iso8601()
        }}
      end
    else
      Logger.info("[PredictionWorker] Prediction recording disabled, skipping")
      {:ok, %{skipped: true, reason: :disabled}}
    end
  end

  @doc """
  Process markets and record predictions, respecting limits and existing predictions.
  """
  def process_markets(markets, max_predictions) do
    now = DateTime.utc_now()

    Enum.reduce_while(markets, {0, 0, []}, fn market_data, {recorded, skipped, results} ->
      if recorded >= max_predictions do
        {:halt, {recorded, skipped, results}}
      else
        condition_id = market_data.market.condition_id

        # Check if recent prediction exists (within 24h)
        if Polymarket.prediction_exists?(condition_id, 24) do
          {:cont, {recorded, skipped + 1, results}}
        else
          case create_prediction(market_data, now) do
            {:ok, prediction} ->
              Logger.debug("[PredictionWorker] Recorded prediction for #{truncate(market_data.market.question, 50)}")
              {:cont, {recorded + 1, skipped, [prediction | results]}}

            {:error, reason} ->
              Logger.warning("[PredictionWorker] Failed to create prediction: #{inspect(reason)}")
              {:cont, {recorded, skipped + 1, results}}
          end
        end
      end
    end)
  end

  @doc """
  Create a prediction for a market based on suspicious trading activity.
  """
  def create_prediction(market_data, now) do
    # Determine predicted outcome from volume consensus
    {predicted_outcome, confidence} = Prediction.determine_prediction(
      market_data.yes_volume,
      market_data.no_volume
    )

    prediction_id = Prediction.generate_prediction_id(
      market_data.market.condition_id,
      now
    )

    attrs = %{
      prediction_id: prediction_id,
      market_id: market_data.market.id,
      condition_id: market_data.market.condition_id,
      market_question: market_data.market.question,
      market_category: to_string(market_data.market.category),
      predicted_at: now,
      market_end_date: market_data.market.end_date,
      watchability_score: Decimal.from_float(market_data.watchability),
      max_ensemble_score: market_data.max_ensemble,
      avg_ensemble_score: market_data.avg_ensemble,
      suspicious_trade_count: market_data.suspicious_trade_count,
      suspicious_volume: market_data.suspicious_volume,
      unique_suspicious_wallets: market_data.unique_wallets,
      top_wallet_address: market_data.top_wallet && market_data.top_wallet.wallet_address,
      top_wallet_score: market_data.top_wallet && market_data.top_wallet.max_score,
      top_wallet_trade_count: market_data.top_wallet && market_data.top_wallet.trade_count,
      predicted_outcome: predicted_outcome,
      prediction_confidence: confidence,
      prediction_tier: market_data.tier,
      suspicious_yes_volume: market_data.yes_volume,
      suspicious_no_volume: market_data.no_volume
    }

    Polymarket.create_prediction(attrs)
  end

  # ============================================
  # Private Helpers
  # ============================================

  defp truncate(nil, _), do: ""
  defp truncate(str, max) when byte_size(str) > max do
    String.slice(str, 0, max - 3) <> "..."
  end
  defp truncate(str, _), do: str

  # ============================================
  # Configuration
  # ============================================

  defp config do
    Application.get_env(:volfefe_machine, __MODULE__, [])
  end

  defp enabled? do
    Keyword.get(config(), :enabled, true)
  end

  defp config_min_watchability do
    Keyword.get(config(), :min_watchability, @default_min_watchability)
  end

  defp config_max_predictions do
    Keyword.get(config(), :max_predictions, @default_max_predictions)
  end
end
