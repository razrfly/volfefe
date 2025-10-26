defmodule VolfefeMachine.Content.Source do
  @moduledoc """
  Schema for external content sources.

  Internal to Content context - use VolfefeMachine.Content API for access.
  """
  use Ecto.Schema
  import Ecto.Changeset

  schema "sources" do
    field :name, :string
    field :adapter, :string
    field :base_url, :string
    field :last_fetched_at, :utc_datetime
    field :last_cursor, :string
    field :meta, :map
    field :enabled, :boolean, default: true

    has_many :contents, VolfefeMachine.Content.Content

    timestamps(type: :utc_datetime)
  end

  @doc false
  def changeset(source, attrs) do
    source
    |> cast(attrs, [:name, :adapter, :base_url, :last_fetched_at, :last_cursor, :meta, :enabled])
    |> validate_required([:name, :adapter])
    |> unique_constraint(:name)
  end
end
