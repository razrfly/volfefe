defmodule VolfefeMachine.Polymarket.InsiderReferenceCase do
  @moduledoc """
  Ecto schema for known/suspected insider trading reference cases.

  Stores ground truth data for validating insider detection algorithms.
  Includes cases from multiple platforms (Polymarket, NYSE, Coinbase, etc.)
  to provide pattern reference and validation targets.

  ## Status Values

  - `confirmed` - Proven through prosecution, investigation findings, or official confirmation
  - `suspected` - Strong circumstantial evidence but not officially confirmed
  - `investigated` - Under active investigation by authorities

  ## Pattern Types

  - `new_account_large_bet` - Fresh account makes unusually large wager
  - `surge_before_secret` - Volume spike before secret committee decision
  - `embargo_breach` - Bets when embargoed data becomes accessible
  - `serial_front_running` - Repeated wins across multiple events
  - `pre_merger_options` - Options activity before M&A announcements
  - `executive_insider` - Corporate insider trading on own company
  - `pre_disclosure_options` - Options before material disclosure
  - `injury_info_leak` - Sports bets on non-public injury info

  ## Usage

      # List all reference cases
      Repo.all(InsiderReferenceCase)

      # Filter by platform
      from(r in InsiderReferenceCase, where: r.platform == "polymarket")

      # Filter by status
      from(r in InsiderReferenceCase, where: r.status == "confirmed")
  """

  use Ecto.Schema
  import Ecto.Changeset

  @platforms ~w(polymarket kalshi nyse nasdaq coinbase sportsbook other)
  @statuses ~w(confirmed suspected investigated cleared)
  @categories ~w(politics tech crypto sports awards entertainment corporate legal other)
  @pattern_types ~w(
    new_account_large_bet
    surge_before_secret
    embargo_breach
    serial_front_running
    pre_merger_options
    executive_insider
    pre_disclosure_options
    injury_info_leak
    perfect_accuracy_multiple
    other
  )

  schema "insider_reference_cases" do
    # Core identification
    field :case_name, :string
    field :event_date, :date
    field :platform, :string
    field :category, :string

    # Market linkage (for Polymarket cases)
    field :condition_id, :string
    field :market_slug, :string
    field :market_question, :string

    # Key metrics
    field :reported_profit, :decimal
    field :reported_bet_size, :decimal

    # Classification
    field :pattern_type, :string
    field :status, :string, default: "suspected"

    # Documentation
    field :description, :string
    field :source_urls, {:array, :string}, default: []

    # Data ingestion tracking
    field :trades_ingested_at, :utc_datetime
    field :trades_count, :integer, default: 0

    # Discovery results (Phase 3)
    # Wallets flagged as suspicious: [%{address: "0x...", volume: 12345, whale_trades: 3, ...}, ...]
    field :discovered_wallets, {:array, :map}, default: []
    # All candidate condition_ids found during discovery
    field :discovered_condition_ids, {:array, :string}, default: []
    # Notes from analysis process
    field :analysis_notes, :string
    # When discovery was last run
    field :discovery_run_at, :utc_datetime
    # Discovery metadata (window, trade count, etc.)
    field :discovery_meta, :map, default: %{}

    timestamps(type: :utc_datetime)
  end

  @required_fields ~w(case_name platform)a
  @optional_fields ~w(
    event_date category reported_profit reported_bet_size
    pattern_type status description source_urls
    condition_id market_slug market_question
    trades_ingested_at trades_count
    discovered_wallets discovered_condition_ids analysis_notes
    discovery_run_at discovery_meta
  )a

  def changeset(reference_case, attrs) do
    reference_case
    |> cast(attrs, @required_fields ++ @optional_fields)
    |> validate_required(@required_fields)
    |> validate_inclusion(:platform, @platforms)
    |> validate_inclusion(:status, @statuses)
    |> validate_inclusion(:category, @categories ++ [nil])
    |> validate_inclusion(:pattern_type, @pattern_types ++ [nil])
    |> unique_constraint(:case_name)
  end

  @doc "Returns valid platforms."
  def platforms, do: @platforms

  @doc "Returns valid statuses."
  def statuses, do: @statuses

  @doc "Returns valid categories."
  def categories, do: @categories

  @doc "Returns valid pattern types."
  def pattern_types, do: @pattern_types
end
