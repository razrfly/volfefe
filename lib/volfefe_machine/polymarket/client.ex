defmodule VolfefeMachine.Polymarket.Client do
  @moduledoc """
  HTTP client for Polymarket public APIs with automatic failover.

  **Endpoints Used**:
  - `data-api.polymarket.com` - Trades, wallet activity, positions (PUBLIC)
  - `gamma-api.polymarket.com` - Market discovery (PUBLIC)
  - Goldsky subgraph (fallback) - Blockchain-indexed trade data

  **No authentication required** - All endpoints are publicly accessible.

  ## Automatic Failover

  Trade-related operations automatically fall back to blockchain subgraph
  when the centralized API is unavailable. Health status is tracked by
  `DataSourceHealth` for intelligent failover decisions.

  ## Rate Limits

  Rate limits have not been documented by Polymarket. Testing suggests
  reasonable usage (100s of requests per minute) is acceptable.

  ## Usage

      # Get recent trades (auto-failover enabled)
      {:ok, trades} = Client.get_trades(limit: 100)

      # Force API-only (no failover)
      {:ok, trades} = Client.get_trades(limit: 100, failover: false)

      # Get trades for specific market
      {:ok, trades} = Client.get_trades(market: "0x123...", limit: 100)

      # Get wallet activity
      {:ok, activity} = Client.get_wallet_activity("0x123...")

      # Get active markets
      {:ok, markets} = Client.get_markets(active: true, limit: 50)
  """

  require Logger

  alias VolfefeMachine.Polymarket.DataSourceHealth
  alias VolfefeMachine.Polymarket.SubgraphClient
  alias VolfefeMachine.Polymarket.VpnClient

  @data_api_base "https://data-api.polymarket.com"
  @gamma_api_base "https://gamma-api.polymarket.com"

  @default_timeout 60_000
  @default_limit 100

  # ============================================
  # Trade Data (data-api)
  # ============================================

  @doc """
  Get recent trades, optionally filtered by market.

  Automatically falls back to blockchain subgraph if centralized API fails.

  ## Parameters

  - `opts` - Keyword list of options:
    - `:market` - Filter by condition_id (optional)
    - `:limit` - Number of trades (default: 100)
    - `:offset` - Pagination offset (default: 0)
    - `:failover` - Enable subgraph fallback (default: true)

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

      # Disable failover (API only)
      {:ok, trades} = Client.get_trades(limit: 50, failover: false)
  """
  def get_trades(opts \\ []) do
    failover = Keyword.get(opts, :failover, true)
    market = Keyword.get(opts, :market)
    limit = Keyword.get(opts, :limit, @default_limit)
    offset = Keyword.get(opts, :offset, 0)

    params =
      [limit: limit, offset: offset]
      |> maybe_add_param(:market, market)
      |> build_query_string()

    url = "#{@data_api_base}/trades#{params}"

    case make_request_with_health(url) do
      {:ok, trades} when is_list(trades) ->
        {:ok, trades}

      {:ok, other} ->
        Logger.warning("Unexpected trades response format: #{inspect(other)}")
        {:error, "Unexpected response format"}

      {:error, reason} = error ->
        if failover do
          Logger.info("[Client] API failed (#{inspect(reason)}), falling back to subgraph")
          broadcast_failover(:api, :subgraph, reason)
          get_trades_from_subgraph(opts)
        else
          error
        end
    end
  end

  @doc false
  def broadcast_failover(from_source, to_source, reason) do
    Phoenix.PubSub.broadcast(
      VolfefeMachine.PubSub,
      "data_source:failover",
      {:failover, %{from: from_source, to: to_source, reason: reason, timestamp: DateTime.utc_now()}}
    )
  end

  @doc """
  Get trades directly from subgraph (bypasses API).

  ## Parameters

  Same as `get_trades/1`.

  ## Returns

  - `{:ok, [trade]}` - List of trade maps (subgraph format)
  - `{:error, reason}` - Error message
  """
  def get_trades_from_subgraph(opts \\ []) do
    limit = Keyword.get(opts, :limit, @default_limit)
    market = Keyword.get(opts, :market)

    subgraph_opts = [
      limit: limit,
      order_by: "timestamp",
      order_direction: "desc"
    ]

    result = if market do
      # Get token IDs for this market and filter trades
      case SubgraphClient.get_token_ids_for_condition(market) do
        {:ok, []} ->
          Logger.warning("[Client] No token IDs found for market #{market}")
          {:ok, []}

        {:ok, token_ids} ->
          # Fetch trades for first token ID (Yes outcome)
          # Note: For complete market coverage, would need to fetch both outcomes
          first_token = List.first(token_ids)
          SubgraphClient.get_order_filled_events(Keyword.put(subgraph_opts, :token_id, first_token))

        error ->
          error
      end
    else
      SubgraphClient.get_order_filled_events(subgraph_opts)
    end

    case result do
      {:ok, events} ->
        record_subgraph_result(:success)
        trades = transform_subgraph_events_to_trades(events)
        {:ok, trades}

      {:error, reason} = error ->
        record_subgraph_result({:failure, reason})
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
  Search markets by keyword.

  Useful for finding markets related to specific topics like
  "Nobel Prize", "OpenAI", "Google Year in Search", etc.

  ## Parameters

  - `query` - Search keyword or phrase
  - `opts` - Keyword list of options:
    - `:closed` - Include closed markets (default: true for historical lookup)
    - `:limit` - Number of markets (default: 20)
    - `:offset` - Pagination offset (default: 0)

  ## Returns

  - `{:ok, [market]}` - List of matching markets
  - `{:error, reason}` - Error message

  ## Response Fields

  Each market contains:
  - `conditionId` - Unique market identifier (use this to link reference cases)
  - `question` - Market question text
  - `slug` - URL slug
  - `endDate` - Market end date
  - `closed` - Whether market is closed
  - `resolvedOutcome` - Resolution result if resolved

  ## Examples

      # Find Nobel Prize markets
      {:ok, markets} = Client.search_markets("Nobel Peace Prize 2025")

      # Find OpenAI markets
      {:ok, markets} = Client.search_markets("OpenAI")

      # Search with limit
      {:ok, markets} = Client.search_markets("Google", limit: 50)
  """
  def search_markets(query, opts \\ []) do
    closed = Keyword.get(opts, :closed, true)
    limit = Keyword.get(opts, :limit, 20)
    offset = Keyword.get(opts, :offset, 0)

    params =
      build_query_string(
        _q: query,
        closed: closed,
        limit: limit,
        offset: offset
      )

    url = "#{@gamma_api_base}/markets#{params}"

    case make_request(url) do
      {:ok, markets} when is_list(markets) ->
        {:ok, markets}

      {:ok, other} ->
        Logger.warning("Unexpected search response format: #{inspect(other)}")
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

    # Use VPN proxy for Gamma/CLOB APIs (geo-blocked for US users)
    case VpnClient.get(url, receive_timeout: @default_timeout) do
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

  defp make_request_with_health(url) do
    result = make_request(url)

    case result do
      {:ok, _} ->
        record_api_result(:success)
        result

      {:error, reason} ->
        record_api_result({:failure, reason})
        result
    end
  end

  defp record_api_result(:success) do
    try do
      DataSourceHealth.record_api_success()
    rescue
      _ -> :ok
    end
  end

  defp record_api_result({:failure, _reason}) do
    try do
      DataSourceHealth.record_api_failure()
    rescue
      _ -> :ok
    end
  end

  defp record_subgraph_result(:success) do
    try do
      DataSourceHealth.record_subgraph_success()
    rescue
      _ -> :ok
    end
  end

  defp record_subgraph_result({:failure, _reason}) do
    try do
      DataSourceHealth.record_subgraph_failure()
    rescue
      _ -> :ok
    end
  end

  # Transform subgraph order filled events to API-like trade format
  defp transform_subgraph_events_to_trades(events) when is_list(events) do
    Enum.map(events, &transform_subgraph_event/1)
  end

  defp transform_subgraph_event(event) do
    # Subgraph events have different field names than API trades
    # makerAssetId/takerAssetId are token IDs (256-bit integers)
    # makerAmountFilled/takerAmountFilled are in wei (divide by 10^6 for USDC)

    maker_amount = parse_wei_amount(event["makerAmountFilled"])
    taker_amount = parse_wei_amount(event["takerAmountFilled"])

    # Determine side: if takerAssetId is "0" (USDC), it's a BUY
    side = if event["takerAssetId"] == "0", do: "BUY", else: "SELL"

    # Calculate price from amounts
    price = if maker_amount > 0, do: taker_amount / maker_amount, else: 0.0

    %{
      # Map subgraph fields to API-like fields
      "proxyWallet" => event["taker"],
      "maker" => event["maker"],
      "side" => side,
      "size" => to_string(maker_amount),
      "price" => price,
      "timestamp" => parse_timestamp(event["timestamp"]),
      "makerAssetId" => event["makerAssetId"],
      "takerAssetId" => event["takerAssetId"],
      "makerAmountFilled" => event["makerAmountFilled"],
      "takerAmountFilled" => event["takerAmountFilled"],
      # Note: These fields are not available from subgraph
      "conditionId" => nil,
      "title" => nil,
      "outcome" => nil,
      "transactionHash" => extract_tx_hash(event["id"]),
      "pseudonym" => nil,
      # Mark as from subgraph for downstream handling
      "_source" => "subgraph"
    }
  end

  defp parse_wei_amount(nil), do: 0.0
  defp parse_wei_amount(amount) when is_binary(amount) do
    case Integer.parse(amount) do
      {n, _} -> n / 1_000_000  # Convert from wei (10^6) to USDC
      :error -> 0.0
    end
  end
  defp parse_wei_amount(amount) when is_integer(amount), do: amount / 1_000_000

  defp parse_timestamp(nil), do: nil
  defp parse_timestamp(ts) when is_binary(ts) do
    case Integer.parse(ts) do
      {n, _} -> n
      :error -> nil
    end
  end
  defp parse_timestamp(ts) when is_integer(ts), do: ts

  defp extract_tx_hash(nil), do: nil
  defp extract_tx_hash(event_id) when is_binary(event_id) do
    # Event ID format is typically "txHash-logIndex"
    case String.split(event_id, "-") do
      [tx_hash | _] -> tx_hash
      _ -> event_id
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
