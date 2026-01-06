defmodule VolfefeMachine.Polymarket.Trade do
  @moduledoc """
  Ecto schema for Polymarket trades.

  Caches individual trade events from the Polymarket API.
  The `transaction_hash` is the unique blockchain transaction identifier.

  Includes both raw trade data and calculated metrics for insider detection.
  """

  use Ecto.Schema
  import Ecto.Changeset

  schema "polymarket_trades" do
    # API reference
    field :transaction_hash, :string

    # Foreign keys
    belongs_to :market, VolfefeMachine.Polymarket.Market
    belongs_to :wallet, VolfefeMachine.Polymarket.Wallet

    # Denormalized for fast queries
    field :wallet_address, :string
    field :condition_id, :string

    # Trade details
    field :side, :string
    field :outcome, :string
    field :outcome_index, :integer
    field :size, :decimal
    field :price, :decimal
    field :usdc_size, :decimal
    field :trade_timestamp, :utc_datetime

    # Calculated metrics (for pattern detection)
    field :size_percentile, :decimal
    field :hours_before_resolution, :decimal
    field :wallet_age_days, :integer
    field :wallet_trade_count, :integer
    field :price_extremity, :decimal

    # Outcome tracking
    field :was_correct, :boolean
    field :profit_loss, :decimal

    # Raw API response
    field :meta, :map

    timestamps(type: :utc_datetime)
  end

  @required_fields ~w(transaction_hash wallet_address condition_id side outcome size price trade_timestamp)a
  @optional_fields ~w(
    market_id wallet_id
    outcome_index usdc_size
    size_percentile hours_before_resolution wallet_age_days
    wallet_trade_count price_extremity
    was_correct profit_loss meta
  )a

  @doc """
  Creates a changeset for inserting a new trade.
  """
  def changeset(trade, attrs) do
    trade
    |> cast(attrs, @required_fields ++ @optional_fields)
    |> validate_required(@required_fields)
    |> unique_constraint(:transaction_hash)
    |> validate_inclusion(:side, ["BUY", "SELL"])
    |> validate_number(:price, greater_than_or_equal_to: 0, less_than_or_equal_to: 1)
    |> foreign_key_constraint(:market_id)
    |> foreign_key_constraint(:wallet_id)
  end

  @doc """
  Creates a changeset for updating calculated metrics.
  """
  def metrics_changeset(trade, attrs) do
    trade
    |> cast(attrs, ~w(
      size_percentile hours_before_resolution wallet_age_days
      wallet_trade_count price_extremity was_correct profit_loss
    )a)
  end

  @doc """
  Calculates price extremity - how far the price is from 0.5 (even odds).
  Returns a value between 0 and 0.5, where 0.5 means extreme odds.
  """
  def calculate_price_extremity(price) when is_number(price) do
    abs(price - 0.5)
  end

  def calculate_price_extremity(%Decimal{} = price) do
    price
    |> Decimal.sub(Decimal.new("0.5"))
    |> Decimal.abs()
  end

  @doc """
  Calculates hours before resolution for a trade.
  Returns nil if market has no resolution date.
  """
  def calculate_hours_before_resolution(trade_timestamp, resolution_date)
      when is_struct(trade_timestamp, DateTime) and is_struct(resolution_date, DateTime) do
    seconds = DateTime.diff(resolution_date, trade_timestamp, :second)
    Float.round(seconds / 3600, 2)
  end

  def calculate_hours_before_resolution(_, _), do: nil

  @doc """
  Determines if the trade outcome was correct based on market resolution.
  """
  def determine_correctness(trade_outcome, resolved_outcome) do
    trade_outcome == resolved_outcome
  end

  @doc """
  Estimates profit/loss for a trade based on outcome.
  For a winning BUY: profit = size * (1 - price)
  For a losing BUY: loss = size * price (negative)
  """
  def estimate_profit_loss(side, size, price, was_correct) do
    size = ensure_decimal(size)
    price = ensure_decimal(price)

    case {side, was_correct} do
      {"BUY", true} ->
        # Won: paid `price` per share, got $1 per share
        Decimal.mult(size, Decimal.sub(Decimal.new(1), price))

      {"BUY", false} ->
        # Lost: paid `price` per share, got $0
        Decimal.mult(size, price) |> Decimal.negate()

      {"SELL", true} ->
        # Sold at `price`, outcome was as bet (complex, depends on position)
        Decimal.mult(size, price)

      {"SELL", false} ->
        # Sold at `price`, outcome was opposite
        Decimal.mult(size, Decimal.sub(Decimal.new(1), price)) |> Decimal.negate()

      _ ->
        nil
    end
  end

  defp ensure_decimal(%Decimal{} = d), do: d
  defp ensure_decimal(n) when is_number(n), do: Decimal.from_float(n * 1.0)
  defp ensure_decimal(s) when is_binary(s), do: Decimal.new(s)
end
