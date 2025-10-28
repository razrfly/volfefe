defmodule VolfefeMachine.MarketData do
  @moduledoc """
  Context module for market data operations.

  Provides lookup and search functions for assets loaded from Alpaca Markets API.
  Simple API for entity resolution and reference data queries.

  ## Examples

      # Get asset by symbol
      {:ok, asset} = MarketData.get_by_symbol("AAPL")

      # Search for assets
      assets = MarketData.search("apple")

      # List all active tradable assets
      assets = MarketData.list_active()

      # Get total asset count
      count = MarketData.count()
  """

  import Ecto.Query
  alias VolfefeMachine.Repo
  alias VolfefeMachine.MarketData.{Asset, Snapshot}

  @doc """
  Gets an asset by its ticker symbol.

  Returns the asset if found, otherwise returns an error tuple.

  ## Parameters

  - `symbol` - Ticker symbol (case insensitive, e.g., "AAPL", "aapl")

  ## Returns

  - `{:ok, asset}` - Asset struct if found
  - `{:error, :not_found}` - If symbol doesn't exist

  ## Examples

      iex> MarketData.get_by_symbol("AAPL")
      {:ok, %Asset{symbol: "AAPL", name: "Apple Inc.", ...}}

      iex> MarketData.get_by_symbol("INVALID")
      {:error, :not_found}
  """
  def get_by_symbol(symbol) when is_binary(symbol) do
    symbol = String.upcase(symbol)

    case Repo.get_by(Asset, symbol: symbol) do
      nil -> {:error, :not_found}
      asset -> {:ok, asset}
    end
  end

  @doc """
  Searches for assets by name or symbol.

  Performs case-insensitive partial matching on both name and symbol fields.
  Returns matching assets ordered by symbol, limited by default to 20 results.

  ## Parameters

  - `query` - Search term (case insensitive)
  - `opts` - Options keyword list
    - `:limit` - Maximum results to return (default: 20)

  ## Returns

  List of matching Asset structs, empty list if no matches.

  ## Examples

      iex> MarketData.search("apple")
      [%Asset{symbol: "AAPL", name: "Apple Inc.", ...}]

      iex> MarketData.search("AA")
      [%Asset{symbol: "AAPL", ...}, %Asset{symbol: "AAL", ...}, ...]

      iex> MarketData.search("AA", limit: 5)
      [%Asset{symbol: "AAPL", ...}, %Asset{symbol: "AAL", ...}, ...]

      iex> MarketData.search("nonexistent")
      []
  """
  def search(query, opts \\ []) when is_binary(query) do
    search_pattern = "%#{query}%"
    limit = Keyword.get(opts, :limit, 20)

    from(a in Asset,
      where: ilike(a.symbol, ^search_pattern) or ilike(a.name, ^search_pattern),
      order_by: a.symbol,
      limit: ^limit
    )
    |> Repo.all()
  end

  @doc """
  Lists all active, tradable assets.

  Returns all assets with status = :active and tradable = true,
  ordered by symbol.

  ## Returns

  List of active Asset structs.

  ## Examples

      iex> MarketData.list_active()
      [%Asset{symbol: "AAPL", status: :active, tradable: true, ...}, ...]
  """
  def list_active do
    from(a in Asset,
      where: a.status == :active and a.tradable == true,
      order_by: a.symbol
    )
    |> Repo.all()
  end

  @doc """
  Returns the total count of assets in the database.

  ## Returns

  Integer count of all assets.

  ## Examples

      iex> MarketData.count()
      5148
  """
  def count do
    Repo.aggregate(Asset, :count)
  end

  @doc """
  Lists assets with optional filters.

  ## Options

  - `:exchange` - Filter by exchange (e.g., "NASDAQ", "NYSE")
  - `:class` - Filter by asset class (e.g., :us_equity, :crypto)
  - `:status` - Filter by status (e.g., :active, :inactive)
  - `:tradable` - Filter by tradable flag (true/false)
  - `:limit` - Limit number of results

  ## Examples

      # Get first 100 NASDAQ stocks
      assets = MarketData.list(exchange: "NASDAQ", limit: 100)

      # Get all active crypto assets
      assets = MarketData.list(class: :crypto, status: :active)
  """
  def list(opts \\ []) do
    Asset
    |> maybe_filter_exchange(opts)
    |> maybe_filter_class(opts)
    |> maybe_filter_status(opts)
    |> maybe_filter_tradable(opts)
    |> maybe_limit(opts)
    |> order_by([a], a.symbol)
    |> Repo.all()
  end

  # Private query builders

  defp maybe_filter_exchange(query, opts) do
    case Keyword.get(opts, :exchange) do
      nil -> query
      exchange -> from(a in query, where: a.exchange == ^exchange)
    end
  end

  defp maybe_filter_class(query, opts) do
    case Keyword.get(opts, :class) do
      nil -> query
      class -> from(a in query, where: a.class == ^class)
    end
  end

  defp maybe_filter_status(query, opts) do
    case Keyword.get(opts, :status) do
      nil -> query
      status -> from(a in query, where: a.status == ^status)
    end
  end

  defp maybe_filter_tradable(query, opts) do
    case Keyword.get(opts, :tradable) do
      nil -> query
      tradable -> from(a in query, where: a.tradable == ^tradable)
    end
  end

  defp maybe_limit(query, opts) do
    case Keyword.get(opts, :limit) do
      nil -> query
      limit -> from(a in query, limit: ^limit)
    end
  end

  @doc """
  Gets impact summary for a content posting.

  Returns aggregate metrics from all market snapshots for the content:
  - Maximum z-score across all assets and windows
  - Highest significance level
  - Isolation score
  - Asset-specific impacts

  ## Parameters

  - `content_id` - Content ID

  ## Returns

  - `{:ok, summary}` - Map with impact metrics
  - `{:error, :no_snapshots}` - No snapshots found

  ## Summary Map

  - `:max_z_score` - Highest absolute z-score
  - `:significance` - "high", "moderate", or "noise"
  - `:isolation_score` - Contamination score (0.0-1.0)
  - `:snapshot_count` - Total snapshots captured
  - `:assets` - List of asset impacts with symbols and z-scores

  ## Examples

      iex> MarketData.get_impact_summary(123)
      {:ok, %{
        max_z_score: 2.68,
        significance: "high",
        isolation_score: 1.0,
        snapshot_count: 24,
        assets: [
          %{symbol: "SPY", max_z_score: 2.68, window: "1hr_after"},
          %{symbol: "QQQ", max_z_score: 1.85, window: "4hr_after"}
        ]
      }}
  """
  def get_impact_summary(content_id) do
    snapshots =
      from(s in Snapshot,
        where: s.content_id == ^content_id,
        preload: [:asset]
      )
      |> Repo.all()

    case snapshots do
      [] ->
        {:error, :no_snapshots}

      snapshots ->
        # Get max z-score across all snapshots
        max_z_score =
          snapshots
          |> Enum.map(& &1.z_score)
          |> Enum.reject(&is_nil/1)
          |> Enum.map(&Decimal.to_float/1)
          |> Enum.map(&abs/1)
          |> Enum.max(fn -> 0.0 end)

        # Determine overall significance
        significance =
          cond do
            max_z_score >= 2.0 -> "high"
            max_z_score >= 1.0 -> "moderate"
            true -> "noise"
          end

        # Get isolation score (same for all snapshots)
        isolation_score =
          case List.first(snapshots) do
            nil -> Decimal.new("0.0")
            snapshot -> snapshot.isolation_score || Decimal.new("0.0")
          end

        # Group by asset and get max z-score per asset
        asset_impacts =
          snapshots
          |> Enum.group_by(& &1.asset_id)
          |> Enum.map(fn {_asset_id, asset_snapshots} ->
            # Find snapshot with max absolute z-score
            snapshots_with_z = Enum.reject(asset_snapshots, &is_nil(&1.z_score))

            max_snapshot =
              if length(snapshots_with_z) > 0 do
                Enum.max_by(snapshots_with_z, fn s -> abs(Decimal.to_float(s.z_score)) end)
              else
                List.first(asset_snapshots)
              end

            %{
              symbol: max_snapshot.asset.symbol,
              max_z_score: if(max_snapshot.z_score, do: Decimal.to_float(max_snapshot.z_score), else: 0.0),
              window: max_snapshot.window_type,
              significance: max_snapshot.significance_level || "noise"
            }
          end)
          |> Enum.sort_by(& abs(&1.max_z_score), :desc)

        summary = %{
          max_z_score: max_z_score,
          significance: significance,
          isolation_score: Decimal.to_float(isolation_score),
          snapshot_count: length(snapshots),
          assets: asset_impacts
        }

        {:ok, summary}
    end
  end
end
