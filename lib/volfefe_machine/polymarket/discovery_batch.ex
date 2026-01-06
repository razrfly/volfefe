defmodule VolfefeMachine.Polymarket.DiscoveryBatch do
  @moduledoc """
  Ecto schema for discovery batches.

  Tracks each discovery run with its parameters, results, and metadata.
  Used for auditing, reproducing results, and comparing batch performance.

  ## Batch Lifecycle

  1. Create batch with parameters
  2. Run discovery (scores trades, extracts candidates)
  3. Update with results (counts, scores)
  4. Complete batch

  ## Usage

      # Start a new discovery batch
      {:ok, batch} = Polymarket.start_discovery_batch(%{
        anomaly_threshold: 0.6,
        probability_threshold: 0.5
      })

      # Run discovery
      {:ok, candidates} = Polymarket.run_discovery(batch)

      # Complete batch
      {:ok, batch} = Polymarket.complete_discovery_batch(batch)
  """

  use Ecto.Schema
  import Ecto.Changeset

  schema "polymarket_discovery_batches" do
    field :batch_id, :string

    # Counts
    field :markets_analyzed, :integer
    field :trades_scored, :integer
    field :candidates_generated, :integer

    # Parameters
    field :anomaly_threshold, :decimal
    field :probability_threshold, :decimal
    field :filters, :map

    # Versions for reproducibility
    field :patterns_version, :string
    field :baselines_version, :string

    # Results
    field :top_candidate_score, :decimal
    field :median_candidate_score, :decimal

    # Timing
    field :started_at, :utc_datetime
    field :completed_at, :utc_datetime
    field :notes, :string

    timestamps(type: :utc_datetime)
  end

  @required_fields ~w(batch_id)a
  @optional_fields ~w(
    markets_analyzed trades_scored candidates_generated
    anomaly_threshold probability_threshold filters
    patterns_version baselines_version
    top_candidate_score median_candidate_score
    started_at completed_at notes
  )a

  def changeset(batch, attrs) do
    batch
    |> cast(attrs, @required_fields ++ @optional_fields)
    |> validate_required(@required_fields)
    |> unique_constraint(:batch_id)
  end

  @doc """
  Generates a unique batch ID based on timestamp.
  """
  def generate_batch_id do
    timestamp = DateTime.utc_now() |> DateTime.to_unix()
    random = :crypto.strong_rand_bytes(4) |> Base.encode16(case: :lower)
    "discovery_#{timestamp}_#{random}"
  end

  @doc """
  Calculates duration of batch run in seconds.
  """
  def duration(%__MODULE__{started_at: started, completed_at: completed})
      when not is_nil(started) and not is_nil(completed) do
    DateTime.diff(completed, started)
  end
  def duration(_), do: nil

  @doc """
  Returns summary stats for a completed batch.
  """
  def summary(%__MODULE__{} = batch) do
    %{
      batch_id: batch.batch_id,
      trades_scored: batch.trades_scored,
      candidates_generated: batch.candidates_generated,
      top_score: batch.top_candidate_score,
      median_score: batch.median_candidate_score,
      duration_seconds: duration(batch),
      thresholds: %{
        anomaly: batch.anomaly_threshold,
        probability: batch.probability_threshold
      }
    }
  end
end
