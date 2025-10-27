defmodule VolfefeMachine.Intelligence.ContentTarget do
  @moduledoc """
  Schema representing the relationship between content and targeted assets.

  ContentTargets link pieces of content (tweets, articles, posts) to the
  specific market assets (stocks, crypto, etc.) they mention or reference.

  This enables:
  - Sentiment analysis scoped to specific assets
  - Asset-specific content filtering and aggregation
  - Context preservation for how assets are mentioned
  - Tracking extraction methods and confidence scores

  ## Fields

  * `:content_id` - Foreign key to contents table
  * `:asset_id` - Foreign key to assets table (references assets.id, NOT alpaca_id)
  * `:extraction_method` - How the target was identified (manual, ner, regex, keyword, ai)
  * `:confidence` - Confidence score (0.0-1.0) of the extraction
  * `:context` - Text snippet where asset was mentioned
  * `:mention_text` - Exact text that triggered the match (e.g., "Tesla", "TSLA")
  * `:meta` - Additional metadata (NER output, alternatives, debugging info)

  ## Examples

      # Manual target creation
      iex> %ContentTarget{}
      ...> |> ContentTarget.changeset(%{
      ...>   content_id: 1,
      ...>   asset_id: 2,
      ...>   extraction_method: :manual,
      ...>   confidence: 1.0,
      ...>   context: "Apple announced new iPhone"
      ...> })
      %Ecto.Changeset{valid?: true}

      # NER extraction with confidence
      iex> %ContentTarget{}
      ...> |> ContentTarget.changeset(%{
      ...>   content_id: 1,
      ...>   asset_id: 2,
      ...>   extraction_method: :ner,
      ...>   confidence: 0.87,
      ...>   context: "AAPL shares rose 5%"
      ...> })
      %Ecto.Changeset{valid?: true}
  """

  use Ecto.Schema
  import Ecto.Changeset

  alias VolfefeMachine.Content.Content
  alias VolfefeMachine.MarketData.Asset

  schema "content_targets" do
    belongs_to :content, Content
    belongs_to :asset, Asset

    field :extraction_method, Ecto.Enum,
      values: [:manual, :ner, :regex, :keyword, :ai]

    field :confidence, :float
    field :context, :string
    field :mention_text, :string
    field :meta, :map

    timestamps(type: :utc_datetime)
  end

  @doc """
  Creates a changeset for a content target.

  ## Validations

  * Required: content_id, asset_id, extraction_method
  * confidence must be between 0.0 and 1.0
  * extraction_method must be valid enum value

  ## Examples

      iex> changeset(%ContentTarget{}, %{
      ...>   content_id: 1,
      ...>   asset_id: 2,
      ...>   extraction_method: :ner,
      ...>   confidence: 0.95
      ...> })
      %Ecto.Changeset{valid?: true}

      iex> changeset(%ContentTarget{}, %{confidence: 1.5})
      %Ecto.Changeset{valid?: false, errors: [confidence: {"must be less than or equal to %{number}", ...}]}
  """
  def changeset(content_target, attrs) do
    content_target
    |> cast(attrs, [:content_id, :asset_id, :extraction_method, :confidence, :context, :mention_text, :meta])
    |> validate_required([:content_id, :asset_id, :extraction_method])
    |> validate_number(:confidence, greater_than_or_equal_to: 0.0, less_than_or_equal_to: 1.0)
    |> foreign_key_constraint(:content_id)
    |> foreign_key_constraint(:asset_id)
    |> unique_constraint([:content_id, :asset_id],
         name: :content_targets_content_asset_unique,
         message: "asset already targeted by this content")
  end
end
