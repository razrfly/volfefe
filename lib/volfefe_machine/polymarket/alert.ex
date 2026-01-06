defmodule VolfefeMachine.Polymarket.Alert do
  @moduledoc """
  Ecto schema for real-time insider trading alerts.

  Generated when trades match suspicious patterns or exceed anomaly thresholds
  during real-time monitoring.

  ## Alert Types

  - `pattern_match` - Trade matches a known insider pattern
  - `anomaly_threshold` - Anomaly score exceeds configured threshold
  - `whale_trade` - Unusually large trade size
  - `timing_suspicious` - Trade close to market resolution
  - `combined` - Multiple alert triggers

  ## Severity Levels

  - `critical` - Immediate investigation required (probability >0.9)
  - `high` - High priority (probability 0.7-0.9)
  - `medium` - Standard review (probability 0.5-0.7)
  - `low` - Watchlist (probability <0.5)

  ## Status Workflow

  ```
  new → acknowledged → investigating → resolved
            ↓
        dismissed
  ```

  ## Usage

      # List new alerts
      alerts = Polymarket.list_alerts(status: "new", severity: "critical")

      # Acknowledge alert
      Polymarket.acknowledge_alert(alert, "analyst@example.com")

      # Resolve alert
      Polymarket.resolve_alert(alert, "confirmed_insider", notes: "...")
  """

  use Ecto.Schema
  import Ecto.Changeset

  @alert_types ~w(pattern_match anomaly_threshold whale_trade timing_suspicious combined manual)
  @severities ~w(low medium high critical)
  @statuses ~w(new acknowledged investigating resolved dismissed)

  schema "polymarket_alerts" do
    belongs_to :trade, VolfefeMachine.Polymarket.Trade
    belongs_to :trade_score, VolfefeMachine.Polymarket.TradeScore
    belongs_to :market, VolfefeMachine.Polymarket.Market

    # Alert identification
    field :alert_id, :string
    field :alert_type, :string

    # Trade context
    field :transaction_hash, :string
    field :wallet_address, :string
    field :condition_id, :string

    # Alert details
    field :severity, :string, default: "medium"
    field :anomaly_score, :decimal
    field :insider_probability, :decimal

    # Context (denormalized)
    field :market_question, :string
    field :trade_size, :decimal
    field :trade_outcome, :string
    field :trade_price, :decimal

    # Pattern matching
    field :matched_patterns, :map
    field :highest_pattern_score, :decimal

    # Alert lifecycle
    field :status, :string, default: "new"
    field :acknowledged_at, :utc_datetime
    field :acknowledged_by, :string
    field :resolution, :string
    field :resolution_notes, :string

    # Notification tracking
    field :notifications_sent, :map, default: %{}

    # Timestamps
    field :triggered_at, :utc_datetime
    field :trade_timestamp, :utc_datetime

    timestamps(type: :utc_datetime)
  end

  @required_fields ~w(alert_id alert_type wallet_address triggered_at)a
  @optional_fields ~w(
    trade_id trade_score_id market_id
    transaction_hash condition_id
    severity anomaly_score insider_probability
    market_question trade_size trade_outcome trade_price
    matched_patterns highest_pattern_score
    status acknowledged_at acknowledged_by
    resolution resolution_notes
    notifications_sent trade_timestamp
  )a

  def changeset(alert, attrs) do
    alert
    |> cast(attrs, @required_fields ++ @optional_fields)
    |> validate_required(@required_fields)
    |> validate_inclusion(:alert_type, @alert_types)
    |> validate_inclusion(:severity, @severities)
    |> validate_inclusion(:status, @statuses)
    |> unique_constraint(:alert_id)
  end

  @doc """
  Returns valid alert types.
  """
  def alert_types, do: @alert_types

  @doc """
  Returns valid severity levels.
  """
  def severities, do: @severities

  @doc """
  Returns valid status values.
  """
  def statuses, do: @statuses

  @doc """
  Generates a unique alert ID based on trade and timestamp.
  """
  def generate_alert_id(trade_id \\ nil) do
    timestamp = DateTime.utc_now() |> DateTime.to_unix(:millisecond)
    random = :crypto.strong_rand_bytes(4) |> Base.encode16(case: :lower)
    trade_part = if trade_id, do: "_t#{trade_id}", else: ""
    "alert_#{timestamp}#{trade_part}_#{random}"
  end

  @doc """
  Calculates severity based on insider probability and anomaly score.
  """
  def calculate_severity(insider_probability, anomaly_score \\ nil) do
    prob = ensure_float(insider_probability)
    anomaly = ensure_float(anomaly_score)

    # Use the higher signal
    signal = max(prob, anomaly * 0.8)

    cond do
      signal >= 0.9 -> "critical"
      signal >= 0.7 -> "high"
      signal >= 0.5 -> "medium"
      true -> "low"
    end
  end

  @doc """
  Determines the alert type based on what triggered the alert.
  """
  def determine_alert_type(triggers) when is_list(triggers) do
    cond do
      length(triggers) > 1 -> "combined"
      "pattern" in triggers -> "pattern_match"
      "anomaly" in triggers -> "anomaly_threshold"
      "whale" in triggers -> "whale_trade"
      "timing" in triggers -> "timing_suspicious"
      true -> "anomaly_threshold"
    end
  end

  def determine_alert_type(_), do: "anomaly_threshold"

  defp ensure_float(%Decimal{} = d), do: Decimal.to_float(d)
  defp ensure_float(n) when is_float(n), do: n
  defp ensure_float(n) when is_integer(n), do: n * 1.0
  defp ensure_float(nil), do: 0.0
end
