defmodule VolfefeMachine.Polymarket.WatchedMarket do
  @moduledoc """
  Ecto schema for watched/starred markets.

  Allows users to track markets they're interested in monitoring closely.
  Watched markets appear in a dedicated section on the main dashboard.
  """

  use Ecto.Schema
  import Ecto.Changeset

  alias VolfefeMachine.Polymarket.Market

  schema "watched_markets" do
    belongs_to :market, Market
    field :notes, :string

    timestamps(type: :utc_datetime)
  end

  @doc """
  Creates a changeset for watching a market.
  """
  def changeset(watched_market, attrs) do
    watched_market
    |> cast(attrs, [:market_id, :notes])
    |> validate_required([:market_id])
    |> unique_constraint(:market_id)
    |> foreign_key_constraint(:market_id)
  end
end
