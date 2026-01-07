defmodule VolfefeMachine.Polymarket.Client do
  @moduledoc """
  HTTP client for Polymarket public APIs.

  **Endpoints Used**:
  - `data-api.polymarket.com` - Trades, wallet activity, positions (PUBLIC)
  - `gamma-api.polymarket.com` - Market discovery (PUBLIC)

  **No authentication required** - All endpoints are publicly accessible.

  ## Rate Limits

  Rate limits have not been documented by Polymarket. Testing suggests
  reasonable usage (100s of requests per minute) is acceptable.

  ## Usage

      # Get recent trades
      {:ok, trades} = Client.get_trades(limit: 100)

      # Get trades for specific market
      {:ok, trades} = Client.get_trades(market: "0x123...", limit: 100)

      # Get wallet activity
      {:ok, activity} = Client.get_wallet_activity("0x123...")

      # Get active markets
      {:ok, markets} = Client.get_markets(active: true, limit: 50)
  """

  require Logger

  @data_api_base "https://data-api.polymarket.com"
  @gamma_api_base "https://gamma-api.polymarket.com"

  @default_timeout 30_000
  @default_limit 100

  # ============================================
  # Trade Data (data-api)
  # ============================================

  @doc """
  Get recent trades, optionally filtered by market.

  ## Parameters

  - `opts` - Keyword list of options:
    - `:market` - Filter by condition_id (optional)
    - `:limit` - Number of trades (default: 100)
    - `:offset` - Pagination offset (default: 0)

  ## Returns

  - `{:ok, [trade]}` - List of trade maps
  - `{:error, reason}` - Error message

  ## Response Fields

  Each trade contains:
  - `proxyWallet` - Wallet address
  - `side` - "BUY" or "SELL"
  - `size` - Trade size in outcome tokens
  - `price` - Execution price (0-1)
  - `timestamp` - Unix timestamp
  - `conditionId` - Market identifier
  - `title` - Market question
  - `outcome` - "Yes" or "No"
  - `transactionHash` - Blockchain transaction hash
  - `pseudonym` - Auto-generated display name

  ## Examples

      # Recent trades across all markets
      {:ok, trades} = Client.get_trades(limit: 50)

      # Trades for specific market
      {:ok, trades} = Client.get_trades(market: "0xabc123", limit: 100)

      # With pagination
      {:ok, page2} = Client.get_trades(limit: 100, offset: 100)
  """
  def get_trades(opts \\ []) do
    market = Keyword.get(opts, :market)
    limit = Keyword.get(opts, :limit, @default_limit)
    offset = Keyword.get(opts, :offset, 0)

    params =
      [limit: limit, offset: offset]
      |> maybe_add_param(:market, market)
      |> build_query_string()

    url = "#{@data_api_base}/trades#{params}"

    case make_request(url) do
      {:ok, trades} when is_list(trades) ->
        {:ok, trades}

      {:ok, other} ->
        Logger.warning("Unexpected trades response format: #{inspect(other)}")
        {:error, "Unexpected response format"}

      error ->
        error
    end
  end

  @doc """
  Get all trading activity for a wallet across all markets.

  ## Parameters

  - `wallet_address` - The proxy wallet address
  - `opts` - Keyword list of options:
    - `:limit` - Number of activities (default: 100)
    - `:offset` - Pagination offset (default: 0)

  ## Returns

  - `{:ok, [activity]}` - List of activity maps
  - `{:error, reason}` - Error message

  ## Response Fields

  Each activity contains trade fields plus:
  - `type` - Activity type (e.g., "TRADE")
  - `usdcSize` - USD value of trade

  ## Examples

      {:ok, activity} = Client.get_wallet_activity("0x123...")
      {:ok, more} = Client.get_wallet_activity("0x123...", limit: 500, offset: 100)
  """
  def get_wallet_activity(wallet_address, opts \\ []) do
    limit = Keyword.get(opts, :limit, @default_limit)
    offset = Keyword.get(opts, :offset, 0)

    params = build_query_string(user: wallet_address, limit: limit, offset: offset)
    url = "#{@data_api_base}/activity#{params}"

    case make_request(url) do
      {:ok, activity} when is_list(activity) ->
        {:ok, activity}

      {:ok, other} ->
        Logger.warning("Unexpected activity response format: #{inspect(other)}")
        {:error, "Unexpected response format"}

      error ->
        error
    end
  end

  @doc """
  Get current open positions for a wallet.

  ## Parameters

  - `wallet_address` - The proxy wallet address

  ## Returns

  - `{:ok, [position]}` - List of position maps
  - `{:error, reason}` - Error message

  ## Response Fields

  Each position contains:
  - `proxyWallet` - Wallet address
  - `size` - Position size
  - `avgPrice` - Average entry price
  - `initialValue` - Cost basis
  - `currentValue` - Current market value
  - `cashPnl` - Unrealized P&L in USD
  - `percentPnl` - Unrealized P&L percentage
  - `realizedPnl` - Closed position P&L
  - `curPrice` - Current market price
  - `title` - Market question

  ## Examples

      {:ok, positions} = Client.get_wallet_positions("0x123...")
  """
  def get_wallet_positions(wallet_address) do
    params = build_query_string(user: wallet_address)
    url = "#{@data_api_base}/positions#{params}"

    case make_request(url) do
      {:ok, positions} when is_list(positions) ->
        {:ok, positions}

      {:ok, other} ->
        Logger.warning("Unexpected positions response format: #{inspect(other)}")
        {:error, "Unexpected response format"}

      error ->
        error
    end
  end

  # ============================================
  # Market Discovery (gamma-api)
  # ============================================

  @doc """
  Get markets from the gamma API.

  ## Parameters

  - `opts` - Keyword list of options:
    - `:active` - Filter to active markets (default: true)
    - `:closed` - Include closed markets (default: false)
    - `:order` - Sort field (default: "volume24hr")
    - `:ascending` - Sort direction (default: false)
    - `:limit` - Number of markets (default: 100)
    - `:offset` - Pagination offset (default: 0)

  ## Returns

  - `{:ok, [market]}` - List of market maps
  - `{:error, reason}` - Error message

  ## Response Fields

  Each market contains:
  - `conditionId` - Unique market identifier
  - `question` - Market question text
  - `description` - Detailed description
  - `slug` - URL slug
  - `outcomes` - Available outcomes
  - `outcomePrices` - Current prices for each outcome
  - `volume24hr` - 24-hour trading volume
  - `volume` - Total volume
  - `liquidity` - Available liquidity
  - `endDate` - Market end date
  - `closed` - Whether market is closed
  - `resolvedOutcome` - Resolution result if resolved

  ## Examples

      # Active markets by volume
      {:ok, markets} = Client.get_markets(limit: 50)

      # Include closed markets
      {:ok, all} = Client.get_markets(closed: true, limit: 100)

      # Sort by liquidity
      {:ok, liquid} = Client.get_markets(order: "liquidity", limit: 50)
  """
  def get_markets(opts \\ []) do
    active = Keyword.get(opts, :active, true)
    closed = Keyword.get(opts, :closed, false)
    order = Keyword.get(opts, :order, "volume24hr")
    ascending = Keyword.get(opts, :ascending, false)
    limit = Keyword.get(opts, :limit, @default_limit)
    offset = Keyword.get(opts, :offset, 0)

    params =
      build_query_string(
        active: active,
        closed: closed,
        order: order,
        ascending: ascending,
        limit: limit,
        offset: offset
      )

    url = "#{@gamma_api_base}/markets#{params}"

    case make_request(url) do
      {:ok, markets} when is_list(markets) ->
        {:ok, markets}

      {:ok, other} ->
        Logger.warning("Unexpected markets response format: #{inspect(other)}")
        {:error, "Unexpected response format"}

      error ->
        error
    end
  end

  @doc """
  Get a single market by condition ID.

  ## Parameters

  - `condition_id` - The market's condition ID

  ## Returns

  - `{:ok, market}` - Market map
  - `{:error, reason}` - Error message

  ## Examples

      {:ok, market} = Client.get_market("0xabc123...")
  """
  def get_market(condition_id) do
    url = "#{@gamma_api_base}/markets/#{condition_id}"

    case make_request(url) do
      {:ok, market} when is_map(market) ->
        {:ok, market}

      {:ok, [market]} when is_map(market) ->
        {:ok, market}

      {:ok, []} ->
        {:error, "Market not found"}

      {:ok, other} ->
        Logger.warning("Unexpected market response format: #{inspect(other)}")
        {:error, "Unexpected response format"}

      error ->
        error
    end
  end

  @doc """
  Get events (market groups) from the gamma API.

  ## Parameters

  - `opts` - Keyword list of options:
    - `:closed` - Include closed events (default: false)
    - `:limit` - Number of events (default: 50)
    - `:offset` - Pagination offset (default: 0)

  ## Returns

  - `{:ok, [event]}` - List of event maps
  - `{:error, reason}` - Error message

  ## Examples

      {:ok, events} = Client.get_events(limit: 20)
  """
  def get_events(opts \\ []) do
    closed = Keyword.get(opts, :closed, false)
    limit = Keyword.get(opts, :limit, 50)
    offset = Keyword.get(opts, :offset, 0)

    params = build_query_string(closed: closed, limit: limit, offset: offset)
    url = "#{@gamma_api_base}/events#{params}"

    case make_request(url) do
      {:ok, events} when is_list(events) ->
        {:ok, events}

      {:ok, other} ->
        Logger.warning("Unexpected events response format: #{inspect(other)}")
        {:error, "Unexpected response format"}

      error ->
        error
    end
  end

  # ============================================
  # Bulk Operations
  # ============================================

  @doc """
  Fetch all trades for a market by paginating through results.

  Automatically handles pagination to retrieve complete trade history.
  Use with caution on high-volume markets.

  ## Parameters

  - `condition_id` - The market's condition ID
  - `opts` - Keyword list of options:
    - `:max_trades` - Maximum trades to fetch (default: 10_000)
    - `:page_size` - Trades per request (default: 100)

  ## Returns

  - `{:ok, [trade]}` - All trades for the market
  - `{:error, reason}` - Error message

  ## Examples

      {:ok, all_trades} = Client.get_all_market_trades("0xabc123")
      {:ok, limited} = Client.get_all_market_trades("0xabc123", max_trades: 500)
  """
  def get_all_market_trades(condition_id, opts \\ []) do
    max_trades = Keyword.get(opts, :max_trades, 10_000)
    page_size = Keyword.get(opts, :page_size, 100)

    fetch_all_pages(
      fn offset -> get_trades(market: condition_id, limit: page_size, offset: offset) end,
      page_size,
      max_trades
    )
  end

  @doc """
  Fetch complete activity history for a wallet.

  Automatically handles pagination to retrieve full history.

  ## Parameters

  - `wallet_address` - The proxy wallet address
  - `opts` - Keyword list of options:
    - `:max_activities` - Maximum activities to fetch (default: 10_000)
    - `:page_size` - Activities per request (default: 100)

  ## Returns

  - `{:ok, [activity]}` - All activities for the wallet
  - `{:error, reason}` - Error message

  ## Examples

      {:ok, all_activity} = Client.get_all_wallet_activity("0x123...")
  """
  def get_all_wallet_activity(wallet_address, opts \\ []) do
    max_activities = Keyword.get(opts, :max_activities, 10_000)
    page_size = Keyword.get(opts, :page_size, 100)

    fetch_all_pages(
      fn offset -> get_wallet_activity(wallet_address, limit: page_size, offset: offset) end,
      page_size,
      max_activities
    )
  end

  # ============================================
  # Private Functions
  # ============================================

  defp make_request(url) do
    Logger.debug("Polymarket API request: #{url}")

    case Req.get(url, receive_timeout: @default_timeout) do
      {:ok, %{status: 200, body: body}} ->
        {:ok, body}

      {:ok, %{status: 429}} ->
        Logger.warning("Rate limited by Polymarket API")
        {:error, "Rate limited - please wait before retrying"}

      {:ok, %{status: 404}} ->
        {:error, "Resource not found"}

      {:ok, %{status: code, body: body}} ->
        Logger.warning("Polymarket API returned #{code}: #{inspect(body)}")
        {:error, "API returned status #{code}"}

      {:error, exception} ->
        Logger.error("Polymarket API request failed: #{inspect(exception)}")
        {:error, "HTTP request failed: #{inspect(exception)}"}
    end
  end

  defp build_query_string(params) do
    query =
      params
      |> Enum.reject(fn {_k, v} -> is_nil(v) end)
      |> Enum.map(fn {k, v} -> "#{k}=#{URI.encode_www_form(to_string(v))}" end)
      |> Enum.join("&")

    if query == "", do: "", else: "?" <> query
  end

  defp maybe_add_param(params, _key, nil), do: params
  defp maybe_add_param(params, key, value), do: Keyword.put(params, key, value)

  defp fetch_all_pages(fetch_fn, page_size, max_items, offset \\ 0, acc \\ []) do
    if length(acc) >= max_items do
      {:ok, Enum.take(acc, max_items)}
    else
      case fetch_fn.(offset) do
        {:ok, items} when is_list(items) and length(items) > 0 ->
          new_acc = acc ++ items

          if length(items) < page_size do
            # Last page
            {:ok, Enum.take(new_acc, max_items)}
          else
            # More pages available
            fetch_all_pages(fetch_fn, page_size, max_items, offset + page_size, new_acc)
          end

        {:ok, []} ->
          {:ok, acc}

        {:error, _} = error ->
          if acc == [] do
            error
          else
            # Return what we have if we fail mid-pagination
            Logger.warning("Pagination interrupted, returning #{length(acc)} items")
            {:ok, acc}
          end
      end
    end
  end
end
