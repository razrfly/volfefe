defmodule VolfefeMachine.Intelligence.AnomalyDetector do
  @moduledoc """
  Isolation Forest anomaly detection for insider trading signals.

  Uses scikit-learn's IsolationForest algorithm via Python interop.
  Ideal for detecting anomalous trades in high-dimensional feature space.

  ## Key Advantages

  - Works with extreme class imbalance (few insiders in many trades)
  - Unsupervised - doesn't need labeled insider examples
  - Fast inference once trained
  - Handles high-dimensional feature spaces well

  ## Usage

      # Train and predict on trade features
      features = [
        [2.5, 1.8, 3.2, 0.5, 1.2, 0.8, 2.1],  # Trade 1 z-scores
        [0.3, 0.2, 0.1, 0.4, 0.3, 0.2, 0.1],  # Trade 2 (normal)
        ...
      ]

      {:ok, results} = AnomalyDetector.fit_predict(features, feature_names: @feature_names)
      # Returns anomaly_scores (0-1) and predictions (-1=anomaly, 1=normal)

      # Score new trades with saved model
      {:ok, scores} = AnomalyDetector.predict(new_features, model_path: "path/to/model.joblib")
  """

  require Logger

  # Core 7 z-score features (legacy compatibility)
  @core_feature_names ~w(
    size_zscore
    timing_zscore
    wallet_age_zscore
    wallet_activity_zscore
    price_extremity_zscore
    position_concentration_zscore
    funding_proximity_zscore
  )

  # Full 22-feature set for ML model
  @feature_names ~w(
    size_zscore
    timing_zscore
    wallet_age_zscore
    wallet_activity_zscore
    price_extremity_zscore
    position_concentration_zscore
    funding_proximity_zscore
    raw_size_normalized
    raw_price
    raw_hours_before_resolution
    raw_wallet_age_days
    raw_wallet_trade_count
    is_buy
    outcome_index
    price_confidence
    wallet_win_rate
    wallet_volume_zscore
    wallet_unique_markets_normalized
    funding_amount_normalized
    trade_hour_sin
    trade_hour_cos
    trade_day_sin
    trade_day_cos
  )

  @default_contamination 0.01  # Expect 1% outliers
  @default_n_estimators 100

  defp python_cmd do
    default_path = Path.join(File.cwd!(), "venv/bin/python3")
    Application.get_env(:volfefe_machine, :python_path, default_path)
  end

  defp script_path do
    priv_dir = :code.priv_dir(:volfefe_machine) |> to_string()
    Path.join(priv_dir, "ml/anomaly_detector.py")
  end

  @doc """
  Train model and predict anomaly scores on the same data.

  ## Parameters

  - `features` - List of feature vectors (list of lists)
  - `opts` - Options:
    - `:feature_names` - Names for each feature (default: z-score names)
    - `:contamination` - Expected outlier proportion (default: 0.01)
    - `:n_estimators` - Number of trees (default: 100)

  ## Returns

  ```elixir
  {:ok, %{
    anomaly_scores: [0.85, 0.12, ...],  # 0-1, higher = more anomalous
    predictions: [-1, 1, ...],           # -1 = anomaly, 1 = normal
    confidence: [0.92, 0.78, ...],       # 0-1, higher = more confident
    n_samples: 1000,
    n_features: 7
  }}
  ```
  """
  def fit_predict(features, opts \\ []) do
    feature_names = Keyword.get(opts, :feature_names, @feature_names)
    contamination = Keyword.get(opts, :contamination, @default_contamination)
    n_estimators = Keyword.get(opts, :n_estimators, @default_n_estimators)

    input = %{
      action: "fit_predict",
      features: features,
      feature_names: feature_names,
      contamination: contamination,
      n_estimators: n_estimators
    }

    run_python(input)
  end

  @doc """
  Predict anomaly scores using a saved model.

  ## Parameters

  - `features` - List of feature vectors
  - `opts` - Options:
    - `:model_path` - Path to saved model (required)
  """
  def predict(features, opts \\ []) do
    model_path = Keyword.fetch!(opts, :model_path)

    input = %{
      action: "predict",
      features: features,
      model_path: model_path
    }

    run_python(input)
  end

  @doc """
  Train and save a model for later use.

  ## Parameters

  - `features` - Training feature vectors
  - `model_path` - Where to save the model
  - `opts` - Training options
  """
  def train_and_save(features, model_path, opts \\ []) do
    feature_names = Keyword.get(opts, :feature_names, @feature_names)
    contamination = Keyword.get(opts, :contamination, @default_contamination)
    n_estimators = Keyword.get(opts, :n_estimators, @default_n_estimators)

    input = %{
      action: "fit",
      features: features,
      feature_names: feature_names,
      contamination: contamination,
      n_estimators: n_estimators,
      model_path: model_path
    }

    run_python(input)
  end

  @doc """
  Score trades from the database and return anomaly scores.

  Extracts features from TradeScore records and runs anomaly detection.

  ## Parameters

  - `trade_scores` - List of TradeScore structs
  - `opts` - Options for fit_predict or predict

  ## Returns

  List of maps with trade_id and anomaly data:
  ```elixir
  [%{trade_id: 123, anomaly_score: 0.85, is_anomaly: true, confidence: 0.92}, ...]
  ```
  """
  def score_trades(trade_scores, opts \\ []) when is_list(trade_scores) do
    # Extract feature vectors from trade scores
    features = Enum.map(trade_scores, &extract_features/1)

    case fit_predict(features, opts) do
      {:ok, result} ->
        # Zip results back with trade IDs
        scored = trade_scores
        |> Enum.zip([result.anomaly_scores, result.predictions, result.confidence])
        |> Enum.with_index()
        |> Enum.map(fn {{ts, {score, pred, conf}}, _idx} ->
          %{
            trade_id: ts.trade_id,
            anomaly_score: score,
            is_anomaly: pred == -1,
            confidence: conf
          }
        end)

        {:ok, %{
          trades: scored,
          summary: %{
            total: length(scored),
            anomalies: Enum.count(scored, & &1.is_anomaly),
            avg_score: Enum.sum(result.anomaly_scores) / max(length(result.anomaly_scores), 1)
          }
        }}

      {:error, reason} ->
        {:error, reason}
    end
  end

  @doc """
  Returns the full 22-feature names used for ML anomaly detection.
  """
  def feature_names, do: @feature_names

  @doc """
  Returns the 7 core z-score feature names (legacy compatibility).
  """
  def core_feature_names, do: @core_feature_names

  # ============================================
  # Private Functions
  # ============================================

  defp extract_features(trade_score) do
    # Extract all 22 features for ML model
    [
      # Core z-scores (1-7)
      ensure_float(trade_score.size_zscore),
      ensure_float(trade_score.timing_zscore),
      ensure_float(trade_score.wallet_age_zscore),
      ensure_float(trade_score.wallet_activity_zscore),
      ensure_float(trade_score.price_extremity_zscore),
      ensure_float(trade_score.position_concentration_zscore),
      ensure_float(trade_score.funding_proximity_zscore),
      # Extended features (8-15)
      ensure_float(trade_score.raw_size_normalized),
      ensure_float(trade_score.raw_price),
      ensure_float(trade_score.raw_hours_before_resolution),
      ensure_float(trade_score.raw_wallet_age_days),
      ensure_float(trade_score.raw_wallet_trade_count),
      bool_to_float(trade_score.is_buy),
      ensure_float(trade_score.outcome_index),
      ensure_float(trade_score.price_confidence),
      # Wallet-level features (16-19)
      ensure_float(trade_score.wallet_win_rate),
      ensure_float(trade_score.wallet_volume_zscore),
      ensure_float(trade_score.wallet_unique_markets_normalized),
      ensure_float(trade_score.funding_amount_normalized),
      # Contextual features (20-22 using sin/cos encoding)
      ensure_float(trade_score.trade_hour_sin),
      ensure_float(trade_score.trade_hour_cos),
      ensure_float(trade_score.trade_day_sin),
      ensure_float(trade_score.trade_day_cos)
    ]
  end

  @doc """
  Extract only the 7 core z-score features (for backward compatibility).
  """
  def extract_core_features(trade_score) do
    [
      ensure_float(trade_score.size_zscore),
      ensure_float(trade_score.timing_zscore),
      ensure_float(trade_score.wallet_age_zscore),
      ensure_float(trade_score.wallet_activity_zscore),
      ensure_float(trade_score.price_extremity_zscore),
      ensure_float(trade_score.position_concentration_zscore),
      ensure_float(trade_score.funding_proximity_zscore)
    ]
  end

  defp ensure_float(nil), do: 0.0
  defp ensure_float(%Decimal{} = d), do: Decimal.to_float(d)
  defp ensure_float(n) when is_float(n), do: n
  defp ensure_float(n) when is_integer(n), do: n * 1.0
  defp ensure_float(true), do: 1.0
  defp ensure_float(false), do: 0.0

  defp bool_to_float(true), do: 1.0
  defp bool_to_float(false), do: 0.0
  defp bool_to_float(nil), do: 0.0

  defp run_python(input) do
    temp_file = Path.join(System.tmp_dir!(), "anomaly_input_#{System.unique_integer([:positive])}.json")

    try do
      # Write input to temp file
      File.write!(temp_file, Jason.encode!(input))

      # Run Python script (no timeout option in Elixir 1.18+)
      case System.cmd("sh", ["-c", "cat '#{temp_file}' | '#{python_cmd()}' '#{script_path()}' 2>/dev/null"]) do
        {output, 0} ->
          parse_result(output)

        {output, exit_code} ->
          Logger.error("Anomaly detector failed (exit #{exit_code}): #{output}")
          {:error, {:python_error, exit_code, output}}
      end
    rescue
      e ->
        Logger.error("Failed to run anomaly detector: #{Exception.format(:error, e, __STACKTRACE__)}")
        {:error, {:system_error, e}}
    after
      File.rm(temp_file)
    end
  end

  defp parse_result(json_string) do
    case Jason.decode(json_string) do
      {:ok, %{"error" => error, "message" => message}} ->
        # Keep error as string to avoid atom exhaustion from external input
        {:error, {error, message}}

      {:ok, %{"status" => "success"} = result} ->
        {:ok, %{
          anomaly_scores: result["anomaly_scores"],
          predictions: result["predictions"],
          confidence: result["confidence"],
          raw_scores: result["raw_scores"],
          threshold: result["threshold"],
          n_samples: result["n_samples"],
          n_features: result["n_features"]
        }}

      {:ok, %{"status" => status} = result} ->
        {:ok, Map.put(result, :status, status)}

      {:ok, result} ->
        {:ok, result}

      {:error, reason} ->
        {:error, {:json_decode_error, reason}}
    end
  end
end
