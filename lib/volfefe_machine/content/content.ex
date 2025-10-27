defmodule VolfefeMachine.Content.Content do
  @moduledoc """
  Schema for ingested content from external sources.

  Internal to Content context - use VolfefeMachine.Content API for access.
  """
  use Ecto.Schema
  import Ecto.Changeset

  schema "contents" do
    field :external_id, :string
    field :author, :string
    field :text, :string
    field :url, :string
    field :published_at, :utc_datetime
    field :classified, :boolean, default: false
    field :meta, :map

    belongs_to :source, VolfefeMachine.Content.Source
    has_one :classification, VolfefeMachine.Intelligence.Classification
    has_many :model_classifications, VolfefeMachine.Intelligence.ModelClassification
    has_many :content_targets, VolfefeMachine.Intelligence.ContentTarget
    has_many :targeted_assets, through: [:content_targets, :asset]

    timestamps(type: :utc_datetime)
  end

  @doc false
  def changeset(content, attrs) do
    content
    |> cast(attrs, [:source_id, :external_id, :author, :text, :url, :published_at, :classified, :meta])
    |> validate_required([:source_id, :external_id])
    |> unique_constraint([:source_id, :external_id])
  end
end
