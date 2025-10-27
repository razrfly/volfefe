defmodule VolfefeMachine.Intelligence.ModelClassification do
  @moduledoc """
  Schema for storing individual model classification results.

  Each content item can have multiple model classifications (one per model).
  This stores the raw output from each sentiment analysis model.

  The consensus/final classification is stored in the `classifications` table,
  while this table preserves all individual model results for analysis and debugging.
  """

  use Ecto.Schema
  import Ecto.Changeset

  schema "model_classifications" do
    belongs_to :content, VolfefeMachine.Content.Content

    # Model identification
    field :model_id, :string          # "distilbert", "twitter_roberta", "finbert"
    field :model_version, :string     # Full HuggingFace model path

    # Classification results
    field :sentiment, :string         # "positive", "negative", "neutral"
    field :confidence, :float         # 0.0-1.0

    # Complete metadata from model
    field :meta, :map                 # {raw_scores, processing, text_info, quality, etc.}

    timestamps(type: :utc_datetime)
  end

  @doc """
  Changeset for creating or updating a model classification.
  """
  def changeset(model_classification, attrs) do
    model_classification
    |> cast(attrs, [:content_id, :model_id, :model_version, :sentiment, :confidence, :meta])
    |> validate_required([:content_id, :model_id, :model_version, :sentiment, :confidence])
    |> validate_inclusion(:sentiment, ["positive", "negative", "neutral"])
    |> validate_number(:confidence, greater_than_or_equal_to: 0.0, less_than_or_equal_to: 1.0)
    |> foreign_key_constraint(:content_id)
    |> unique_constraint([:content_id, :model_id, :model_version],
                         name: :model_classifications_unique_idx)
  end
end
