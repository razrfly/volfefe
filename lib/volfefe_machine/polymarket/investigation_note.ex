defmodule VolfefeMachine.Polymarket.InvestigationNote do
  @moduledoc """
  Ecto schema for investigation notes on wallet investigations.

  Allows investigators to add notes, evidence, and observations
  during the investigation process. Notes are attached to a wallet address.
  """

  use Ecto.Schema
  import Ecto.Changeset

  @note_types ~w(general evidence action dismissal)

  schema "polymarket_investigation_notes" do
    field :wallet_address, :string
    field :note_text, :string
    field :author, :string, default: "admin"
    field :note_type, :string, default: "general"

    timestamps(type: :utc_datetime)
  end

  @doc """
  Creates a changeset for an investigation note.
  """
  def changeset(note, attrs) do
    note
    |> cast(attrs, [:wallet_address, :note_text, :author, :note_type])
    |> validate_required([:wallet_address, :note_text])
    |> validate_inclusion(:note_type, @note_types)
    |> update_change(:wallet_address, &String.downcase/1)
  end
end
