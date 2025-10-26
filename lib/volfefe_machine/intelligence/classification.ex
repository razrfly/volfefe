defmodule VolfefeMachine.Intelligence.Classification do
  @moduledoc """
  Schema for storing ML-based sentiment classifications of content.

  Each classification represents a FinBERT analysis of a piece of content,
  storing the predicted sentiment, confidence score, and model version used.

  ## Fields

  * `:sentiment` - The predicted sentiment ("positive", "negative", "neutral")
  * `:confidence` - Confidence score from 0.0 to 1.0
  * `:model_version` - Model identifier (e.g., "finbert-tone-v1.0")
  * `:meta` - Flexible JSONB storage for:
    * `raw_scores` - All three sentiment scores from model
    * `processed_at` - Classification timestamp
    * `latency_ms` - Processing time
    * `model_metadata` - Full model details
    * `errors` - Any processing errors or warnings
  """

  use Ecto.Schema
  import Ecto.Changeset

  alias VolfefeMachine.Content.Content

  @allowed_sentiments ~w(positive negative neutral)

  schema "classifications" do
    field :sentiment, :string
    field :confidence, :float
    field :model_version, :string
    field :meta, :map

    belongs_to :content, Content

    timestamps(type: :utc_datetime)
  end

  @doc """
  Creates a changeset for a classification.

  ## Validations

  * Required: content_id, sentiment, confidence, model_version
  * sentiment must be one of: positive, negative, neutral
  * confidence must be between 0.0 and 1.0
  * content_id must be unique (one classification per content)

  ## Examples

      iex> changeset(%Classification{}, %{
      ...>   content_id: 1,
      ...>   sentiment: "positive",
      ...>   confidence: 0.95,
      ...>   model_version: "finbert-tone-v1.0"
      ...> })
      %Ecto.Changeset{valid?: true}

      iex> changeset(%Classification{}, %{sentiment: "invalid"})
      %Ecto.Changeset{valid?: false}
  """
  def changeset(classification, attrs) do
    classification
    |> cast(attrs, [:content_id, :sentiment, :confidence, :model_version, :meta])
    |> validate_required([:content_id, :sentiment, :confidence, :model_version])
    |> validate_inclusion(:sentiment, @allowed_sentiments)
    |> validate_number(:confidence,
      greater_than_or_equal_to: 0.0,
      less_than_or_equal_to: 1.0
    )
    |> foreign_key_constraint(:content_id)
    |> unique_constraint(:content_id)
  end
end
