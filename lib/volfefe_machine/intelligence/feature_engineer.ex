defmodule VolfefeMachine.Intelligence.FeatureEngineer do
  @moduledoc """
  Feature engineering for ML-based insider trading detection.

  Computes the expanded 22-feature set from raw trade and wallet data:

  ## Core Z-Scores (1-7)
  - size_zscore, timing_zscore, wallet_age_zscore, wallet_activity_zscore
  - price_extremity_zscore, position_concentration_zscore, funding_proximity_zscore

  ## Extended Features (8-15)
  - raw_size_normalized: Trade size normalized by market volume
  - raw_price: Price at trade time (0-1)
  - raw_hours_before_resolution: Hours until market resolution
  - raw_wallet_age_days: Wallet age in days
  - raw_wallet_trade_count: Number of trades by this wallet
  - is_buy: Binary indicator (1=BUY, 0=SELL)
  - outcome_index: Which outcome bet on (0 or 1)
  - price_confidence: How extreme the price is (0=even odds, 1=extreme)

  ## Wallet-Level Features (16-19)
  - wallet_win_rate: Historical win rate
  - wallet_volume_zscore: Z-score of wallet's total volume
  - wallet_unique_markets_normalized: Market diversification (normalized)
  - funding_amount_normalized: Initial deposit size (normalized)

  ## Contextual Features (20-22)
  - trade_hour_sin/cos: Cyclical encoding of hour of day
  - trade_day_sin/cos: Cyclical encoding of day of week
  """

  require Logger

  @doc """
  Compute all 22 features for a trade, given trade and wallet data.

  Returns a map of feature names to values.
  """
  def compute_features(trade, wallet, baselines \\ %{}) do
    # Core z-scores are computed by the existing scoring process
    # Here we compute the extended features

    %{
      # Extended features (8-15)
      raw_size_normalized: compute_raw_size_normalized(trade, baselines),
      raw_price: ensure_float(trade.price),
      raw_hours_before_resolution: ensure_float(trade.hours_before_resolution),
      raw_wallet_age_days: trade.wallet_age_days || 0,
      raw_wallet_trade_count: trade.wallet_trade_count || 0,
      is_buy: trade.side == "BUY",
      outcome_index: trade.outcome_index || 0,
      price_confidence: compute_price_confidence(trade.price),

      # Wallet-level features (16-19)
      wallet_win_rate: ensure_float(wallet && wallet.win_rate),
      wallet_volume_zscore: compute_wallet_volume_zscore(wallet, baselines),
      wallet_unique_markets_normalized: compute_wallet_diversity(wallet),
      funding_amount_normalized: compute_funding_normalized(wallet, baselines),

      # Contextual features (20-22)
      trade_hour_sin: compute_hour_sin(trade.trade_timestamp),
      trade_hour_cos: compute_hour_cos(trade.trade_timestamp),
      trade_day_sin: compute_day_sin(trade.trade_timestamp),
      trade_day_cos: compute_day_cos(trade.trade_timestamp)
    }
  end

  @doc """
  Add computed features to an existing trade score map.
  """
  def enrich_trade_score(score_attrs, trade, wallet, baselines \\ %{}) do
    features = compute_features(trade, wallet, baselines)
    Map.merge(score_attrs, features)
  end

  # ============================================
  # Extended Feature Computations (8-15)
  # ============================================

  defp compute_raw_size_normalized(trade, baselines) do
    size = ensure_float(trade.size)
    max_size = get_baseline_stat(baselines, :trade_size, :max, 100_000)

    if max_size > 0 do
      min(size / max_size, 1.0)
    else
      0.0
    end
  end

  @doc """
  Compute price confidence - how extreme the price is.
  0.5 price = 0.0 confidence (even odds)
  0.0 or 1.0 price = 1.0 confidence (certain)
  nil price = 0.0 confidence (unknown, treated as even odds)
  """
  def compute_price_confidence(nil) do
    # Missing price treated as even odds (0.5) -> confidence 0.0
    0.0
  end

  def compute_price_confidence(price) do
    p = ensure_float(price)
    # abs(price - 0.5) * 2 gives 0 at 0.5 and 1 at 0/1
    abs(p - 0.5) * 2.0
  end

  # ============================================
  # Wallet-Level Feature Computations (16-19)
  # ============================================

  defp compute_wallet_volume_zscore(nil, _baselines), do: 0.0

  defp compute_wallet_volume_zscore(wallet, baselines) do
    volume = ensure_float(wallet.total_volume)
    mean = get_baseline_stat(baselines, :wallet_volume, :mean, 1000)
    stddev = get_baseline_stat(baselines, :wallet_volume, :stddev, 500)

    if stddev > 0 do
      (volume - mean) / stddev
    else
      0.0
    end
  end

  defp compute_wallet_diversity(nil), do: 0.0

  defp compute_wallet_diversity(wallet) do
    markets = wallet.unique_markets || 0
    # Normalize: assume 100 markets is fully diversified
    min(markets / 100.0, 1.0)
  end

  defp compute_funding_normalized(nil, _baselines), do: 0.0

  defp compute_funding_normalized(wallet, baselines) do
    amount = ensure_float(wallet.initial_deposit_amount)
    max_funding = get_baseline_stat(baselines, :funding, :max, 100_000)

    if max_funding > 0 do
      min(amount / max_funding, 1.0)
    else
      0.0
    end
  end

  # ============================================
  # Contextual Feature Computations (20-22)
  # Using cyclical encoding for time features
  # ============================================

  defp compute_hour_sin(nil), do: 0.0

  defp compute_hour_sin(%DateTime{} = dt) do
    hour = dt.hour
    :math.sin(2 * :math.pi() * hour / 24)
  end

  defp compute_hour_cos(nil), do: 0.0

  defp compute_hour_cos(%DateTime{} = dt) do
    hour = dt.hour
    :math.cos(2 * :math.pi() * hour / 24)
  end

  defp compute_day_sin(nil), do: 0.0

  defp compute_day_sin(%DateTime{} = dt) do
    # 1 = Monday, 7 = Sunday
    day = Date.day_of_week(DateTime.to_date(dt))
    :math.sin(2 * :math.pi() * day / 7)
  end

  defp compute_day_cos(nil), do: 0.0

  defp compute_day_cos(%DateTime{} = dt) do
    day = Date.day_of_week(DateTime.to_date(dt))
    :math.cos(2 * :math.pi() * day / 7)
  end

  # ============================================
  # Helper Functions
  # ============================================

  defp get_baseline_stat(baselines, metric, stat, default) do
    baselines
    |> Map.get(metric, %{})
    |> Map.get(stat, default)
    |> ensure_float()
  end

  defp ensure_float(nil), do: 0.0
  defp ensure_float(%Decimal{} = d), do: Decimal.to_float(d)
  defp ensure_float(n) when is_float(n), do: n
  defp ensure_float(n) when is_integer(n), do: n * 1.0
end
