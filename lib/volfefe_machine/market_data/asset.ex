defmodule VolfefeMachine.MarketData.Asset do
  @moduledoc """
  Schema for tradable assets from Alpaca Markets API.

  Stores essential asset information with complete metadata preservation.
  The `meta` field contains the full Alpaca API response for debugging
  and future feature extraction.

  ## Fields

  * `:alpaca_id` - Alpaca's UUID for the asset (primary key)
  * `:symbol` - Trading ticker symbol (e.g., "AAPL")
  * `:name` - Full asset name (e.g., "Apple Inc. Common Stock")
  * `:exchange` - Trading venue (e.g., "NASDAQ", "NYSE")
  * `:class` - Asset type (us_equity, crypto, us_option, other)
  * `:status` - Trading status (active, inactive)
  * `:tradable` - Whether asset can be traded on Alpaca
  * `:meta` - Complete Alpaca API response (JSONB map)

  ## Meta Field

  The `meta` field preserves ALL data from Alpaca's API response, including:
  - Trading attributes (marginable, shortable, fractionable, easy_to_borrow)
  - Margin requirements (maintenance_margin_requirement, margin_requirement_long, margin_requirement_short)
  - Additional attributes (has_options, etc.)
  - Any future fields Alpaca may add

  This ensures no data loss and allows querying without schema migrations:

      iex> asset.meta["marginable"]
      true

      iex> asset.meta["attributes"]
      ["has_options"]
  """

  use Ecto.Schema
  import Ecto.Changeset

  @primary_key {:alpaca_id, :binary_id, autogenerate: false}
  schema "assets" do
    field :symbol, :string
    field :name, :string
    field :exchange, :string
    field :class, Ecto.Enum, values: [:us_equity, :crypto, :us_option, :other]
    field :status, Ecto.Enum, values: [:active, :inactive]
    field :tradable, :boolean
    field :meta, :map

    timestamps(type: :utc_datetime)
  end

  @doc """
  Creates a changeset for an asset.

  ## Validations

  * Required: alpaca_id, symbol, name, class, meta
  * symbol must be unique
  * meta must be present to preserve all Alpaca data

  ## Examples

      iex> changeset(%Asset{}, %{
      ...>   alpaca_id: "904837e3-3b76-47ec-b432-046db621571b",
      ...>   symbol: "AAPL",
      ...>   name: "Apple Inc. Common Stock",
      ...>   class: :us_equity,
      ...>   meta: %{"id" => "904837e3...", "symbol" => "AAPL", ...}
      ...> })
      %Ecto.Changeset{valid?: true}
  """
  def changeset(asset, attrs) do
    asset
    |> cast(attrs, [:alpaca_id, :symbol, :name, :exchange, :class, :status, :tradable, :meta])
    |> validate_required([:alpaca_id, :symbol, :name, :class, :meta])
    |> validate_length(:symbol, min: 1, max: 25)
    |> unique_constraint(:symbol)
  end
end
