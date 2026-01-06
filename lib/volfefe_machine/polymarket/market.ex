defmodule VolfefeMachine.Polymarket.Market do
  @moduledoc """
  Ecto schema for Polymarket markets.

  Caches market metadata from the Polymarket API for fast queries
  and analysis. The `condition_id` is the unique identifier from
  Polymarket that can be used to re-fetch data from the API.
  """

  use Ecto.Schema
  import Ecto.Changeset

  @category_values ~w(politics corporate legal crypto sports entertainment science other)a

  schema "polymarket_markets" do
    field :condition_id, :string
    field :question, :string
    field :description, :string
    field :slug, :string
    field :outcomes, :map, default: %{"options" => ["Yes", "No"]}
    field :outcome_prices, :map

    field :end_date, :utc_datetime
    field :resolution_date, :utc_datetime
    field :resolved_outcome, :string

    field :volume, :decimal
    field :volume_24hr, :decimal
    field :liquidity, :decimal

    field :category, Ecto.Enum, values: @category_values, default: :other
    field :is_event_based, :boolean, default: true
    field :is_active, :boolean, default: true

    field :meta, :map
    field :last_synced_at, :utc_datetime

    has_many :trades, VolfefeMachine.Polymarket.Trade

    timestamps(type: :utc_datetime)
  end

  @required_fields ~w(condition_id question)a
  @optional_fields ~w(
    description slug outcomes outcome_prices
    end_date resolution_date resolved_outcome
    volume volume_24hr liquidity
    category is_event_based is_active
    meta last_synced_at
  )a

  @doc """
  Creates a changeset for inserting or updating a market.
  """
  def changeset(market, attrs) do
    market
    |> cast(attrs, @required_fields ++ @optional_fields)
    |> validate_required(@required_fields)
    |> unique_constraint(:condition_id)
    |> validate_inclusion(:category, @category_values)
  end

  @doc """
  Determines if a market is resolved based on its data.
  """
  def resolved?(%__MODULE__{resolved_outcome: outcome}) when not is_nil(outcome), do: true
  def resolved?(%__MODULE__{}), do: false

  @doc """
  Determines if a market is event-based (vs price-based like crypto).

  Event-based markets are more likely to have insider information value:
  - Politics, corporate events, legal rulings, deaths
  - NOT: crypto price movements, sports scores
  """
  def event_based?(%__MODULE__{category: category}) do
    category in [:politics, :corporate, :legal, :entertainment, :science]
  end

  @doc """
  Categorizes a market based on its question text.
  Returns one of: :politics, :corporate, :legal, :crypto, :sports, :entertainment, :science, :other
  """
  def categorize_from_question(question) when is_binary(question) do
    question_lower = String.downcase(question)

    cond do
      # Politics
      matches_any?(question_lower, ~w(trump biden election president congress senate governor vote republican democrat political impeach)) ->
        :politics

      # Corporate
      matches_any?(question_lower, ~w(ceo earnings stock company ipo acquisition merger layoff bankruptcy)) ->
        :corporate

      # Legal
      matches_any?(question_lower, ~w(court ruling verdict trial lawsuit convicted guilty innocent sentence appeal judge jury)) ->
        :legal

      # Crypto price markets (typically short timeframes)
      matches_any?(question_lower, ~w(bitcoin btc ethereum eth xrp solana)) and matches_any?(question_lower, ~w(price up down 15m 30m 1h)) ->
        :crypto

      # Sports
      matches_any?(question_lower, ~w(nfl nba mlb nhl super bowl championship game win score team player)) ->
        :sports

      # Entertainment
      matches_any?(question_lower, ~w(oscar grammy emmy movie film tv show celebrity actor actress)) ->
        :entertainment

      # Science
      matches_any?(question_lower, ~w(climate weather temperature nasa space discovery research study)) ->
        :science

      true ->
        :other
    end
  end

  defp matches_any?(text, keywords) do
    Enum.any?(keywords, &String.contains?(text, &1))
  end
end
