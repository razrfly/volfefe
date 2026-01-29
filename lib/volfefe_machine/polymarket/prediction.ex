defmodule VolfefeMachine.Polymarket.Prediction do
  @moduledoc """
  Schema for forward predictions on active markets.

  Records predictions BEFORE market resolution to enable validation
  of the system's predictive accuracy.

  ## Lifecycle

  1. **Prediction**: When suspicious activity is detected on an active market,
     a prediction is recorded with the current watchability score and
     predicted outcome (based on what suspicious traders are betting on).

  2. **Pending**: The prediction remains pending until the market resolves.

  3. **Validation**: When the market resolves, the actual outcome is compared
     to the predicted outcome and accuracy metrics are recorded.

  ## Prediction Logic

  The predicted outcome is determined by analyzing which side (Yes/No)
  has more suspicious trading volume:
  - If >70% of suspicious volume is on "Yes", predict "Yes"
  - If >70% of suspicious volume is on "No", predict "No"
  - Otherwise, predict the majority side with lower confidence
  """

  use Ecto.Schema
  import Ecto.Changeset

  alias VolfefeMachine.Polymarket.Market

  schema "polymarket_predictions" do
    # Identifiers
    field :prediction_id, :string
    field :condition_id, :string
    field :market_question, :string
    field :market_category, :string

    # Timing
    field :predicted_at, :utc_datetime
    field :market_end_date, :utc_datetime

    # Prediction data (snapshot at prediction time)
    field :watchability_score, :decimal
    field :max_ensemble_score, :decimal
    field :avg_ensemble_score, :decimal
    field :suspicious_trade_count, :integer, default: 0
    field :suspicious_volume, :decimal
    field :unique_suspicious_wallets, :integer, default: 0

    # Top wallet info
    field :top_wallet_address, :string
    field :top_wallet_score, :decimal
    field :top_wallet_trade_count, :integer

    # Prediction outcome
    field :predicted_outcome, :string
    field :prediction_confidence, :decimal
    field :prediction_tier, :string

    # Consensus data
    field :suspicious_yes_volume, :decimal
    field :suspicious_no_volume, :decimal

    # Resolution tracking
    field :actual_outcome, :string
    field :validated_at, :utc_datetime
    field :prediction_correct, :boolean
    field :days_before_resolution, :decimal
    field :validation_notes, :string

    # Associations
    belongs_to :market, Market

    timestamps()
  end

  @required_fields [
    :prediction_id,
    :predicted_at
  ]

  @optional_fields [
    :market_id,
    :condition_id,
    :market_question,
    :market_category,
    :market_end_date,
    :watchability_score,
    :max_ensemble_score,
    :avg_ensemble_score,
    :suspicious_trade_count,
    :suspicious_volume,
    :unique_suspicious_wallets,
    :top_wallet_address,
    :top_wallet_score,
    :top_wallet_trade_count,
    :predicted_outcome,
    :prediction_confidence,
    :prediction_tier,
    :suspicious_yes_volume,
    :suspicious_no_volume,
    :actual_outcome,
    :validated_at,
    :prediction_correct,
    :days_before_resolution,
    :validation_notes
  ]

  @doc """
  Changeset for creating a new prediction.
  """
  def changeset(prediction, attrs) do
    prediction
    |> cast(attrs, @required_fields ++ @optional_fields)
    |> validate_required(@required_fields)
    |> unique_constraint(:prediction_id)
    |> validate_inclusion(:prediction_tier, ["critical", "high", "medium", "low"])
  end

  @doc """
  Changeset for validating a prediction after market resolution.
  """
  def validation_changeset(prediction, attrs) do
    prediction
    |> cast(attrs, [:actual_outcome, :validated_at, :prediction_correct, :days_before_resolution, :validation_notes])
    |> validate_required([:actual_outcome, :validated_at, :prediction_correct])
  end

  @doc """
  Generate a unique prediction ID based on market and timestamp.
  """
  def generate_prediction_id(condition_id, timestamp) do
    data = "#{condition_id}_#{DateTime.to_unix(timestamp)}"
    :crypto.hash(:sha256, data)
    |> Base.encode16(case: :lower)
    |> String.slice(0..15)
  end

  @doc """
  Calculate prediction confidence based on volume consensus.

  Returns a value between 0.5 and 1.0:
  - 1.0 = 100% consensus (all volume on one side)
  - 0.5 = 50/50 split (no consensus)
  """
  def calculate_confidence(yes_volume, no_volume) do
    total = Decimal.add(yes_volume || Decimal.new(0), no_volume || Decimal.new(0))

    if Decimal.compare(total, Decimal.new(0)) == :eq do
      Decimal.new("0.5")
    else
      yes_pct = Decimal.div(yes_volume || Decimal.new(0), total)
      no_pct = Decimal.div(no_volume || Decimal.new(0), total)

      # Confidence is how far from 50/50 we are
      max_pct = Decimal.max(yes_pct, no_pct)
      # Scale from [0.5, 1.0] -> [0.5, 1.0]
      max_pct
    end
  end

  @doc """
  Determine predicted outcome based on volume consensus.

  Returns {outcome, confidence}:
  - outcome: "Yes" or "No"
  - confidence: 0.5 to 1.0
  """
  def determine_prediction(yes_volume, no_volume) do
    yes_vol = yes_volume || Decimal.new(0)
    no_vol = no_volume || Decimal.new(0)
    total = Decimal.add(yes_vol, no_vol)

    if Decimal.compare(total, Decimal.new(0)) == :eq do
      {"Yes", Decimal.new("0.5")}  # Default with low confidence
    else
      yes_pct = Decimal.div(yes_vol, total)

      if Decimal.compare(yes_pct, Decimal.new("0.5")) == :gt do
        {"Yes", yes_pct}
      else
        {"No", Decimal.sub(Decimal.new(1), yes_pct)}
      end
    end
  end

  @doc """
  Determine prediction tier from watchability score.
  """
  def determine_tier(watchability_score) do
    score = if is_struct(watchability_score, Decimal) do
      Decimal.to_float(watchability_score)
    else
      watchability_score || 0.0
    end

    cond do
      score >= 0.8 -> "critical"
      score >= 0.6 -> "high"
      score >= 0.4 -> "medium"
      true -> "low"
    end
  end
end
