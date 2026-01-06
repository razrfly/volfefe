defmodule VolfefeMachine.Polymarket.ConfirmedInsider do
  @moduledoc """
  Ecto schema for confirmed insider trades.

  Stores labeled training data for the feedback loop:
  - Documented insider cases with evidence
  - Confidence levels (suspected, likely, confirmed)
  - Used to calculate insider-specific baselines

  ## Confidence Levels

  - `suspected` - Pattern matches but no external confirmation
  - `likely` - Strong pattern match + circumstantial evidence
  - `confirmed` - News reports, investigations, or official documentation

  ## Usage

      # Add a confirmed insider case
      Polymarket.add_confirmed_insider(%{
        wallet_address: "0x123...",
        condition_id: "0xabc...",
        confidence_level: "confirmed",
        confirmation_source: "news_report",
        evidence_summary: "Documented by Futurism.com - bet placed 15 mins before announcement",
        evidence_links: %{article: "https://..."}
      })

      # Get all confirmed insiders for training
      insiders = Polymarket.list_confirmed_insiders(confidence_level: "confirmed")
  """

  use Ecto.Schema
  import Ecto.Changeset

  @confidence_levels ~w(suspected likely confirmed)
  @confirmation_sources ~w(news_report investigation blockchain_analysis pattern_match court_filing official_statement)

  schema "polymarket_confirmed_insiders" do
    belongs_to :trade, VolfefeMachine.Polymarket.Trade
    belongs_to :candidate, VolfefeMachine.Polymarket.InvestigationCandidate

    # API references
    field :transaction_hash, :string
    field :wallet_address, :string
    field :condition_id, :string

    # Confirmation details
    field :confidence_level, :string
    field :confirmation_source, :string

    # Evidence
    field :evidence_summary, :string
    field :evidence_links, :map

    # Financial
    field :trade_size, :decimal
    field :estimated_profit, :decimal

    # Training
    field :used_for_training, :boolean, default: false
    field :training_weight, :decimal, default: Decimal.new("1.0")

    field :confirmed_at, :utc_datetime
    field :confirmed_by, :string

    timestamps(type: :utc_datetime)
  end

  @required_fields ~w(wallet_address confidence_level confirmation_source)a
  @optional_fields ~w(
    trade_id candidate_id transaction_hash condition_id
    evidence_summary evidence_links trade_size estimated_profit
    used_for_training training_weight confirmed_at confirmed_by
  )a

  def changeset(insider, attrs) do
    insider
    |> cast(attrs, @required_fields ++ @optional_fields)
    |> validate_required(@required_fields)
    |> validate_inclusion(:confidence_level, @confidence_levels)
    |> validate_inclusion(:confirmation_source, @confirmation_sources)
    |> unique_constraint(:trade_id)
  end

  @doc """
  Returns valid confidence levels.
  """
  def confidence_levels, do: @confidence_levels

  @doc """
  Returns valid confirmation sources.
  """
  def confirmation_sources, do: @confirmation_sources

  @doc """
  Calculates the effective training weight based on confidence level.

  Higher confidence = higher weight in baseline calculations.
  """
  def effective_weight(%__MODULE__{confidence_level: level, training_weight: weight}) do
    base_weight = Decimal.to_float(weight || Decimal.new("1.0"))

    multiplier =
      case level do
        "confirmed" -> 1.0
        "likely" -> 0.7
        "suspected" -> 0.4
      end

    base_weight * multiplier
  end
end
