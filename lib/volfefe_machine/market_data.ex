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
  alias VolfefeMachine.Content.Content

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
        # Phase 1 MVP: Focus on simple price_change_pct instead of z-scores
        # Get max absolute price change across all snapshots
        max_price_change =
          snapshots
          |> Enum.map(& &1.price_change_pct)
          |> Enum.reject(&is_nil/1)
          |> Enum.map(&Decimal.to_float/1)
          |> Enum.map(&abs/1)
          |> Enum.max(fn -> 0.0 end)

        # Determine impact level based on price change magnitude
        # High: >2% move, Moderate: >0.5% move, Low: <=0.5% move
        impact_level =
          cond do
            max_price_change >= 2.0 -> "high"
            max_price_change >= 0.5 -> "moderate"
            true -> "low"
          end

        # Get isolation score (same for all snapshots)
        isolation_score =
          case List.first(snapshots) do
            nil -> Decimal.new("0.0")
            snapshot -> snapshot.isolation_score || Decimal.new("0.0")
          end

        # Group by asset and get max price change per asset
        asset_impacts =
          snapshots
          |> Enum.group_by(& &1.asset_id)
          |> Enum.map(fn {_asset_id, asset_snapshots} ->
            # Find snapshot with max absolute price change
            snapshots_with_price = Enum.reject(asset_snapshots, &is_nil(&1.price_change_pct))

            max_snapshot =
              if length(snapshots_with_price) > 0 do
                Enum.max_by(snapshots_with_price, fn s -> abs(Decimal.to_float(s.price_change_pct)) end)
              else
                List.first(asset_snapshots)
              end

            price_change = if(max_snapshot.price_change_pct, do: Decimal.to_float(max_snapshot.price_change_pct), else: 0.0)

            # Determine asset-specific impact level
            asset_impact_level =
              cond do
                abs(price_change) >= 2.0 -> "high"
                abs(price_change) >= 0.5 -> "moderate"
                true -> "low"
              end

            %{
              symbol: max_snapshot.asset.symbol,
              price_change_pct: price_change,
              window: max_snapshot.window_type,
              impact_level: asset_impact_level
            }
          end)
          |> Enum.sort_by(& abs(&1.price_change_pct), :desc)

        summary = %{
          max_price_change: max_price_change,
          impact_level: impact_level,
          isolation_score: Decimal.to_float(isolation_score),
          snapshot_count: length(snapshots),
          assets: asset_impacts
        }

        {:ok, summary}
    end
  end

  @doc """
  Lists content items with market snapshots.

  Returns content with classification and snapshot counts, ordered by publish date.

  ## Options

  - `:limit` - Limit number of results (default: 50)
  - `:offset` - Offset for pagination (default: 0)
  - `:min_significance` - Filter by minimum significance ("high", "moderate", "noise")
  - `:order_by` - Order by :published_at or :max_z_score (default: :published_at)

  ## Returns

  List of maps with content details and impact summary.

  ## Examples

      iex> MarketData.list_content_with_snapshots(limit: 10)
      [%{
        id: 123,
        text: "Big tariffs coming!",
        published_at: ~U[2025-01-26 10:00:00Z],
        sentiment: "negative",
        confidence: 0.95,
        max_z_score: 2.68,
        significance: "high",
        snapshot_count: 24
      }, ...]
  """
  def list_content_with_snapshots(opts \\ []) do
    limit = Keyword.get(opts, :limit, 50)
    offset = Keyword.get(opts, :offset, 0)
    min_significance = Keyword.get(opts, :min_significance)
    order_by = Keyword.get(opts, :order_by, :published_at)

    # Get content IDs with snapshots
    snapshot_stats =
      from(s in Snapshot,
        group_by: s.content_id,
        select: %{
          content_id: s.content_id,
          snapshot_count: count(s.id),
          max_z_score: max(s.z_score),
          max_isolation_score: max(s.isolation_score)
        }
      )
      |> Repo.all()
      |> Enum.map(fn stats ->
        # Determine significance from max z-score
        significance =
          if stats.max_z_score do
            abs_z = abs(Decimal.to_float(stats.max_z_score))
            cond do
              abs_z >= 2.0 -> "high"
              abs_z >= 1.0 -> "moderate"
              true -> "noise"
            end
          else
            "noise"
          end

        Map.put(stats, :significance, significance)
      end)

    # Filter by significance if requested
    snapshot_stats =
      if min_significance do
        significance_rank = %{"high" => 3, "moderate" => 2, "noise" => 1}
        min_rank = significance_rank[min_significance] || 1

        Enum.filter(snapshot_stats, fn stats ->
          (significance_rank[stats.significance] || 0) >= min_rank
        end)
      else
        snapshot_stats
      end

    # Get content IDs
    content_ids = Enum.map(snapshot_stats, & &1.content_id)

    if length(content_ids) == 0 do
      []
    else
      # Get content with classifications
      contents =
        from(c in Content,
          where: c.id in ^content_ids,
          left_join: cl in assoc(c, :classification),
          select: %{
            id: c.id,
            text: c.text,
            author: c.author,
            url: c.url,
            published_at: c.published_at,
            sentiment: cl.sentiment,
            confidence: cl.confidence
          }
        )
        |> Repo.all()

      # Merge with snapshot stats
      content_map = Map.new(contents, &{&1.id, &1})
      snapshot_map = Map.new(snapshot_stats, &{&1.content_id, &1})

      content_ids
      |> Enum.map(fn id ->
        content = content_map[id]
        stats = snapshot_map[id]

        Map.merge(content, %{
          snapshot_count: stats.snapshot_count,
          max_z_score: if(stats.max_z_score, do: Decimal.to_float(stats.max_z_score), else: 0.0),
          significance: stats.significance,
          isolation_score: if(stats.max_isolation_score, do: Decimal.to_float(stats.max_isolation_score), else: 0.0)
        })
      end)
      |> Enum.sort_by(
        fn item ->
          case order_by do
            :max_z_score -> -abs(item.max_z_score)
            _ -> item.published_at
          end
        end,
        case order_by do
          :max_z_score -> :asc
          _ -> {:desc, DateTime}
        end
      )
      |> Enum.drop(offset)
      |> Enum.take(limit)
    end
  end

  @doc """
  Gets detailed snapshots for a content item grouped by asset.

  Returns all snapshots for the content, grouped by asset with all 4 time windows.

  ## Parameters

  - `content_id` - Content ID

  ## Returns

  - `{:ok, asset_snapshots}` - List of asset snapshot groups
  - `{:error, :no_snapshots}` - No snapshots found

  ## Example Response

      {:ok, [
        %{
          asset: %Asset{symbol: "SPY", name: "SPDR S&P 500 ETF"},
          snapshots: %{
            "before" => %Snapshot{...},
            "1hr_after" => %Snapshot{...},
            "4hr_after" => %Snapshot{...},
            "24hr_after" => %Snapshot{...}
          }
        },
        ...
      ]}
  """
  def get_content_snapshots(content_id) do
    snapshots =
      from(s in Snapshot,
        where: s.content_id == ^content_id,
        preload: [:asset],
        order_by: [s.asset_id, s.window_type]
      )
      |> Repo.all()

    case snapshots do
      [] ->
        {:error, :no_snapshots}

      snapshots ->
        asset_snapshots =
          snapshots
          |> Enum.group_by(& &1.asset_id)
          |> Enum.map(fn {_asset_id, asset_snapshots} ->
            asset = List.first(asset_snapshots).asset

            snapshots_by_window =
              asset_snapshots
              |> Enum.map(&{&1.window_type, &1})
              |> Map.new()

            %{
              asset: asset,
              snapshots: snapshots_by_window
            }
          end)
          |> Enum.sort_by(& &1.asset.symbol)

        {:ok, asset_snapshots}
    end
  end
end
