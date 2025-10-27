defmodule VolfefeMachine.MarketData.Asset do
  @moduledoc """
  Schema for tradable assets from multiple data sources.

  Uses standard auto-increment ID as primary key for source independence.
  External source IDs (alpaca_id, yahoo_id, etc.) stored as unique fields.

  Stores essential asset information with complete metadata preservation.
  The `meta` field contains the full source API response for debugging
  and future feature extraction.

  ## Fields

  * `:id` - Internal auto-increment primary key (standard)
  * `:symbol` - Trading ticker symbol (e.g., "AAPL")
  * `:name` - Full asset name (e.g., "Apple Inc. Common Stock")
  * `:exchange` - Trading venue (e.g., "NASDAQ", "NYSE")
  * `:class` - Asset type (us_equity, crypto, us_option, other)
  * `:status` - Trading status (active, inactive)
  * `:tradable` - Whether asset can be traded
  * `:data_source` - Origin of data ("alpaca", "yahoo", "polygon", "manual")
  * `:alpaca_id` - Alpaca's UUID (nullable, unique when present)
  * `:meta` - Complete source API response (JSONB map)

  ## Multi-Source Support

  The design supports assets from multiple sources:
  - Alpaca Markets (current)
  - Yahoo Finance (future)
  - Polygon (future)
  - Manual entries (future)

  Each source has its own ID field (alpaca_id, yahoo_id, etc.) as a
  nullable unique constraint, not as the primary key.

  ## Meta Field

  The `meta` field preserves ALL data from the source API response, including:
  - Trading attributes (marginable, shortable, fractionable, easy_to_borrow)
  - Margin requirements (maintenance_margin_requirement, margin_requirement_long, margin_requirement_short)
  - Additional attributes (has_options, etc.)
  - Any future fields the source may add

  This ensures no data loss and allows querying without schema migrations:

      iex> asset.meta["marginable"]
      true

      iex> asset.meta["attributes"]
      ["has_options"]
  """

  use Ecto.Schema
  import Ecto.Changeset

  schema "assets" do
    field :symbol, :string
    field :name, :string
    field :exchange, :string
    field :class, Ecto.Enum, values: [:us_equity, :crypto, :us_option, :other]
    field :status, Ecto.Enum, values: [:active, :inactive]
    field :tradable, :boolean

    # Source tracking
    field :data_source, :string
    field :alpaca_id, :binary_id

    field :meta, :map

    has_many :content_targets, VolfefeMachine.Intelligence.ContentTarget
    has_many :targeting_contents, through: [:content_targets, :content]

    timestamps(type: :utc_datetime)
  end

  @doc """
  Creates a changeset for an asset.

  ## Validations

  * Required: symbol, name, class, data_source, meta
  * symbol must be unique (globally)
  * alpaca_id must be unique when present
  * data_source must be valid ("alpaca", "yahoo", "polygon", "manual")
  * meta must be present to preserve all source data

  ## Examples

      # Alpaca asset
      iex> changeset(%Asset{}, %{
      ...>   symbol: "AAPL",
      ...>   name: "Apple Inc. Common Stock",
      ...>   class: :us_equity,
      ...>   data_source: "alpaca",
      ...>   alpaca_id: "904837e3-3b76-47ec-b432-046db621571b",
      ...>   meta: %{"id" => "904837e3...", "symbol" => "AAPL", ...}
      ...> })
      %Ecto.Changeset{valid?: true}

      # Manual asset (no alpaca_id)
      iex> changeset(%Asset{}, %{
      ...>   symbol: "PRIVATE",
      ...>   name: "Private Company Inc",
      ...>   class: :us_equity,
      ...>   data_source: "manual",
      ...>   meta: %{}
      ...> })
      %Ecto.Changeset{valid?: true}
  """
  def changeset(asset, attrs) do
    asset
    |> cast(attrs, [:symbol, :name, :exchange, :class, :status, :tradable,
                    :data_source, :alpaca_id, :meta])
    |> validate_required([:symbol, :name, :class, :data_source, :meta])
    |> validate_length(:symbol, min: 1, max: 25)
    |> validate_inclusion(:data_source, ["alpaca", "yahoo", "polygon", "manual"])
    |> unique_constraint(:symbol)
    |> unique_constraint(:alpaca_id, name: :assets_alpaca_id_unique)
  end
end
