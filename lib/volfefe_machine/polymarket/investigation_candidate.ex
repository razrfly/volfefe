defmodule VolfefeMachine.Polymarket.InvestigationCandidate do
  @moduledoc """
  Ecto schema for investigation candidates.

  Stores top suspicious trades discovered through anomaly detection
  for human review and investigation.

  ## Status Workflow

  ```
  undiscovered → investigating → resolved
                      ↓
                  dismissed
  ```

  ## Priority Levels

  - `critical` - Immediate investigation required (probability >0.9)
  - `high` - High priority (probability 0.7-0.9)
  - `medium` - Standard review (probability 0.5-0.7)
  - `low` - Watchlist (probability <0.5)

  ## Usage

      # Get top candidates for investigation
      candidates = Polymarket.list_investigation_candidates(
        status: "undiscovered",
        limit: 20
      )

      # Start investigation
      Polymarket.update_candidate_status(candidate, "investigating", "analyst@example.com")

      # Resolve as confirmed insider
      Polymarket.resolve_candidate(candidate, %{
        resolution: "confirmed_insider",
        evidence: %{...},
        notes: "Linked to news report..."
      })
  """

  use Ecto.Schema
  import Ecto.Changeset

  @statuses ~w(undiscovered investigating resolved dismissed)
  @priorities ~w(critical high medium low)

  schema "polymarket_investigation_candidates" do
    belongs_to :trade, VolfefeMachine.Polymarket.Trade
    belongs_to :trade_score, VolfefeMachine.Polymarket.TradeScore
    belongs_to :market, VolfefeMachine.Polymarket.Market

    # API references
    field :transaction_hash, :string
    field :wallet_address, :string
    field :condition_id, :string

    # Ranking
    field :discovery_rank, :integer
    field :anomaly_score, :decimal
    field :insider_probability, :decimal

    # Context (denormalized for display)
    field :market_question, :string
    field :trade_size, :decimal
    field :trade_outcome, :string
    field :was_correct, :boolean
    field :estimated_profit, :decimal
    field :hours_before_resolution, :decimal

    # Anomaly details
    field :anomaly_breakdown, :map
    field :matched_patterns, :map

    # Investigation workflow
    field :status, :string, default: "undiscovered"
    field :priority, :string, default: "medium"
    field :assigned_to, :string
    field :investigation_started_at, :utc_datetime
    field :investigation_notes, :string
    field :resolved_at, :utc_datetime
    field :resolved_by, :string
    field :resolution_evidence, :map

    # Batch tracking
    field :batch_id, :string
    field :discovered_at, :utc_datetime

    timestamps(type: :utc_datetime)
  end

  @required_fields ~w(wallet_address discovery_rank anomaly_score insider_probability)a
  @optional_fields ~w(
    trade_id trade_score_id market_id
    transaction_hash condition_id
    market_question trade_size trade_outcome was_correct
    estimated_profit hours_before_resolution
    anomaly_breakdown matched_patterns
    status priority assigned_to
    investigation_started_at investigation_notes
    resolved_at resolved_by resolution_evidence
    batch_id discovered_at
  )a

  def changeset(candidate, attrs) do
    candidate
    |> cast(attrs, @required_fields ++ @optional_fields)
    |> validate_required(@required_fields)
    |> validate_inclusion(:status, @statuses)
    |> validate_inclusion(:priority, @priorities)
    |> unique_constraint(:trade_id)
  end

  @doc """
  Returns valid status values.
  """
  def statuses, do: @statuses

  @doc """
  Returns valid priority values.
  """
  def priorities, do: @priorities

  @doc """
  Calculates priority based on insider probability.
  """
  def calculate_priority(insider_probability) do
    prob = ensure_float(insider_probability)

    cond do
      prob >= 0.9 -> "critical"
      prob >= 0.7 -> "high"
      prob >= 0.5 -> "medium"
      true -> "low"
    end
  end

  @doc """
  Builds anomaly breakdown from trade score z-scores.
  """
  def build_anomaly_breakdown(trade_score) do
    %{
      "size" => format_zscore(trade_score.size_zscore),
      "timing" => format_zscore(trade_score.timing_zscore),
      "wallet_age" => format_zscore(trade_score.wallet_age_zscore),
      "wallet_activity" => format_zscore(trade_score.wallet_activity_zscore),
      "price_extremity" => format_zscore(trade_score.price_extremity_zscore)
    }
    |> Enum.reject(fn {_, v} -> is_nil(v) end)
    |> Map.new()
  end

  defp format_zscore(nil), do: nil
  defp format_zscore(%Decimal{} = d) do
    z = Decimal.to_float(d)
    %{
      "value" => Float.round(z, 3),
      "severity" => classify_zscore(z)
    }
  end

  defp classify_zscore(z) when abs(z) >= 3.0, do: "extreme"
  defp classify_zscore(z) when abs(z) >= 2.5, do: "very_high"
  defp classify_zscore(z) when abs(z) >= 2.0, do: "high"
  defp classify_zscore(z) when abs(z) >= 1.5, do: "elevated"
  defp classify_zscore(_), do: "normal"

  defp ensure_float(%Decimal{} = d), do: Decimal.to_float(d)
  defp ensure_float(n) when is_float(n), do: n
  defp ensure_float(n) when is_integer(n), do: n * 1.0
  defp ensure_float(nil), do: 0.0
end
