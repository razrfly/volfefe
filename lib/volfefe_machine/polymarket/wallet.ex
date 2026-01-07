defmodule VolfefeMachine.Polymarket.Wallet do
  @moduledoc """
  Ecto schema for Polymarket wallets.

  Caches wallet metadata and aggregated trading statistics.
  The `address` is the unique wallet address (proxyWallet) from Polymarket.
  Aggregates are computed from trades and updated periodically.
  """

  use Ecto.Schema
  import Ecto.Changeset

  schema "polymarket_wallets" do
    field :address, :string
    field :pseudonym, :string
    field :display_name, :string

    # Aggregates
    field :total_trades, :integer, default: 0
    field :total_volume, :decimal, default: Decimal.new(0)
    field :unique_markets, :integer, default: 0

    # Win/Loss tracking
    field :resolved_positions, :integer, default: 0
    field :wins, :integer, default: 0
    field :losses, :integer, default: 0
    field :win_rate, :decimal

    # Activity timeline
    field :first_seen_at, :utc_datetime
    field :last_seen_at, :utc_datetime

    # Cache metadata
    field :last_aggregated_at, :utc_datetime

    has_many :trades, VolfefeMachine.Polymarket.Trade

    timestamps(type: :utc_datetime)
  end

  @required_fields ~w(address)a
  @optional_fields ~w(
    pseudonym display_name
    total_trades total_volume unique_markets
    resolved_positions wins losses win_rate
    first_seen_at last_seen_at last_aggregated_at
  )a

  @doc """
  Creates a changeset for inserting or updating a wallet.
  """
  def changeset(wallet, attrs) do
    wallet
    |> cast(attrs, @required_fields ++ @optional_fields)
    |> validate_required(@required_fields)
    |> unique_constraint(:address)
    |> validate_number(:win_rate, greater_than_or_equal_to: 0, less_than_or_equal_to: 1)
  end

  @doc """
  Creates a changeset for updating wallet aggregates.
  """
  def aggregates_changeset(wallet, attrs) do
    wallet
    |> cast(attrs, ~w(
      total_trades total_volume unique_markets
      resolved_positions wins losses win_rate
      first_seen_at last_seen_at last_aggregated_at
    )a)
  end

  @doc """
  Calculates win rate from wins and losses.
  Returns nil if no resolved positions.
  """
  def calculate_win_rate(wins, losses) when is_integer(wins) and is_integer(losses) do
    total = wins + losses

    if total > 0 do
      Decimal.div(Decimal.new(wins), Decimal.new(total))
      |> Decimal.round(4)
    else
      nil
    end
  end

  @doc """
  Determines the age of a wallet in days from first_seen_at.
  Returns nil if first_seen_at is not set.
  """
  def age_in_days(%__MODULE__{first_seen_at: nil}), do: nil

  def age_in_days(%__MODULE__{first_seen_at: first_seen}) do
    DateTime.diff(DateTime.utc_now(), first_seen, :day)
  end
end
