defmodule VolfefeMachine.Polymarket.SubgraphClient do
  @moduledoc """
  GraphQL client for Polymarket subgraphs on Goldsky/The Graph.

  Provides access to blockchain-indexed historical data that is:
  - Not subject to geo-blocking
  - Complete from November 2022 to present
  - Includes all on-chain trades and positions

  ## Subgraphs Available

  | Subgraph | Purpose | Status |
  |----------|---------|--------|
  | orderbook-subgraph | Trade fills, orders | ✅ Active |
  | positions-subgraph | Wallet balances | ✅ Active |
  | oi-subgraph | Open interest | Available |
  | pnl-subgraph | Profit/loss tracking | Available |

  ## Usage

      # Get recent trades
      {:ok, trades} = SubgraphClient.get_order_filled_events(limit: 100)

      # Get historical trades for a time range
      {:ok, trades} = SubgraphClient.get_order_filled_events(
        from_timestamp: 1696118400,  # Oct 1, 2024
        to_timestamp: 1698796800,    # Nov 1, 2024
        limit: 1000
      )

      # Get trades for a specific token (market outcome)
      {:ok, trades} = SubgraphClient.get_order_filled_events(
        token_id: "106181075047366745139197108801635573283215248045056329679360376976893016488727"
      )

      # Get wallet positions
      {:ok, balances} = SubgraphClient.get_user_balances(wallet: "0x123...")

  ## Token ID Mapping

  The subgraph uses condition token IDs (256-bit integers) which map to:
  - Market condition + outcome index
  - These need to be mapped to our `condition_id` for market association
  """

  require Logger

  @subgraph_base "https://api.goldsky.com/api/public/project_cl6mb8i9h0003e201j6li0diw/subgraphs"

  @orderbook_subgraph "#{@subgraph_base}/orderbook-subgraph/0.0.1/gn"
  @positions_subgraph "#{@subgraph_base}/positions-subgraph/0.0.4/gn"
  @oi_subgraph "#{@subgraph_base}/oi-subgraph/0.0.3/gn"
  @pnl_subgraph "#{@subgraph_base}/pnl-subgraph/0.0.1/gn"

  @default_timeout 30_000
  @default_limit 100
  @max_limit 1000  # The Graph's typical limit
  @rate_limit_delay 100  # ms between requests

  # ============================================
  # Order Filled Events (Trades)
  # ============================================

  @doc """
  Get order filled events (trades) from the orderbook subgraph.

  ## Parameters

  - `opts` - Keyword list of options:
    - `:limit` - Number of events (default: 100, max: 1000)
    - `:skip` - Pagination offset (default: 0)
    - `:from_timestamp` - Start timestamp (Unix seconds)
    - `:to_timestamp` - End timestamp (Unix seconds)
    - `:token_id` - Filter by maker or taker asset ID
    - `:maker` - Filter by maker address
    - `:taker` - Filter by taker address
    - `:order_by` - Field to sort by (default: "timestamp")
    - `:order_direction` - "asc" or "desc" (default: "desc")

  ## Returns

  - `{:ok, [event]}` - List of order filled event maps
  - `{:error, reason}` - Error message

  ## Event Fields

  Each event contains:
  - `id` - Unique event ID
  - `timestamp` - Unix timestamp (string)
  - `maker` - Maker wallet address
  - `taker` - Taker wallet address
  - `makerAssetId` - Token being sold (256-bit integer as string)
  - `takerAssetId` - Token being bought ("0" for USDC)
  - `makerAmountFilled` - Amount filled (in wei, divide by 10^6 for USDC)
  - `takerAmountFilled` - Amount filled
  """
  def get_order_filled_events(opts \\ []) do
    limit = min(Keyword.get(opts, :limit, @default_limit), @max_limit)
    skip = Keyword.get(opts, :skip, 0)
    order_by = Keyword.get(opts, :order_by, "timestamp")
    order_direction = Keyword.get(opts, :order_direction, "desc")

    # Build where clause
    where_parts = []
    where_parts = add_timestamp_filter(where_parts, opts[:from_timestamp], opts[:to_timestamp])
    where_parts = add_token_filter(where_parts, opts[:token_id])
    where_parts = add_address_filter(where_parts, :maker, opts[:maker])
    where_parts = add_address_filter(where_parts, :taker, opts[:taker])

    where_clause = build_where_clause(where_parts)

    query = """
    {
      orderFilledEvents(
        first: #{limit}
        skip: #{skip}
        orderBy: #{order_by}
        orderDirection: #{order_direction}
        #{where_clause}
      ) {
        id
        timestamp
        maker
        taker
        makerAssetId
        takerAssetId
        makerAmountFilled
        takerAmountFilled
      }
    }
    """

    execute_query(@orderbook_subgraph, query, "orderFilledEvents")
  end

  @doc """
  Fetch all order filled events with automatic pagination.

  Handles The Graph's 1000 result limit by making multiple requests.

  ## Parameters

  - `opts` - Same as `get_order_filled_events/1` plus:
    - `:max_events` - Maximum total events to fetch (default: 10_000)
    - `:progress_callback` - Function called with progress updates

  ## Returns

  - `{:ok, [event]}` - All events matching criteria
  - `{:error, reason}` - Error message
  """
  def get_all_order_filled_events(opts \\ []) do
    max_events = Keyword.get(opts, :max_events, 10_000)
    progress_callback = Keyword.get(opts, :progress_callback, fn _ -> :ok end)

    fetch_all_with_pagination(
      fn skip ->
        opts
        |> Keyword.put(:skip, skip)
        |> Keyword.put(:limit, @max_limit)
        |> get_order_filled_events()
      end,
      max_events,
      progress_callback
    )
  end

  @doc """
  Get order filled events for a specific time range.

  Convenience function for historical data fetching.

  ## Parameters

  - `from_date` - Start date (Date or DateTime)
  - `to_date` - End date (Date or DateTime)
  - `opts` - Additional options (same as `get_all_order_filled_events/1`)
  """
  def get_order_filled_events_for_range(from_date, to_date, opts \\ []) do
    from_ts = to_unix_timestamp(from_date)
    to_ts = to_unix_timestamp(to_date)

    opts
    |> Keyword.put(:from_timestamp, from_ts)
    |> Keyword.put(:to_timestamp, to_ts)
    |> get_all_order_filled_events()
  end

  # ============================================
  # User Balances (Positions)
  # ============================================

  @doc """
  Get user balance entries from the positions subgraph.

  ## Parameters

  - `opts` - Keyword list of options:
    - `:limit` - Number of balances (default: 100, max: 1000)
    - `:skip` - Pagination offset (default: 0)
    - `:wallet` - Filter by wallet address (required for useful queries)

  ## Returns

  - `{:ok, [balance]}` - List of balance maps
  - `{:error, reason}` - Error message

  ## Balance Fields

  Each balance contains:
  - `id` - Unique balance ID
  - `user` - Wallet address
  - `asset` - Token/condition reference
  - `balance` - Current balance
  """
  def get_user_balances(opts \\ []) do
    limit = min(Keyword.get(opts, :limit, @default_limit), @max_limit)
    skip = Keyword.get(opts, :skip, 0)

    where_parts = []
    where_parts = add_address_filter(where_parts, :user, opts[:wallet])

    where_clause = build_where_clause(where_parts)

    query = """
    {
      userBalances(
        first: #{limit}
        skip: #{skip}
        #{where_clause}
      ) {
        id
        user
        asset {
          id
        }
        balance
      }
    }
    """

    execute_query(@positions_subgraph, query, "userBalances")
  end

  # ============================================
  # Token ID Mapping
  # ============================================

  @doc """
  Get token IDs for a specific condition_id from the subgraph.

  Useful for targeted ingestion of trades for a specific market.

  ## Parameters

  - `condition_id` - The market's condition ID (hex string starting with 0x)
  - `opts` - Keyword list of options:
    - `:max_events` - Maximum events to check (default: 1000)

  ## Returns

  - `{:ok, [token_id]}` - List of token IDs for this condition
  - `{:error, reason}` - Error message
  """
  def get_token_ids_for_condition(condition_id, opts \\ []) do
    limit = min(Keyword.get(opts, :max_events, 1000), @max_limit)

    # Normalize condition_id to lowercase (The Graph stores lowercase)
    normalized_cond = String.downcase(condition_id)

    query = """
    {
      marketDatas(
        first: #{limit}
        where: { condition: "#{normalized_cond}" }
      ) {
        id
        condition
        outcomeIndex
      }
    }
    """

    case execute_query(@orderbook_subgraph, query, "marketDatas") do
      {:ok, data} when is_list(data) ->
        token_ids = Enum.map(data, fn item -> item["id"] end)
        {:ok, token_ids}

      {:ok, nil} ->
        {:ok, []}

      error ->
        error
    end
  end

  @doc """
  Get market information for a specific condition_id.

  Queries the subgraph for market data associated with a condition.
  Note: The subgraph may not have slug/question - those come from Polymarket API.

  ## Parameters

  - `condition_id` - The market's condition ID (hex string starting with 0x)

  ## Returns

  - `{:ok, %{"condition_id" => ..., "token_ids" => [...]}}` - Market info
  - `{:error, reason}` - Error message if not found
  """
  def get_market_info(condition_id) do
    # Normalize condition_id to lowercase
    normalized_cond = String.downcase(condition_id)

    query = """
    {
      marketDatas(
        first: 10
        where: { condition: "#{normalized_cond}" }
      ) {
        id
        condition
        outcomeIndex
      }
    }
    """

    case execute_query(@orderbook_subgraph, query, "marketDatas") do
      {:ok, data} when is_list(data) and length(data) > 0 ->
        token_ids = Enum.map(data, fn item -> item["id"] end)
        {:ok, %{
          "condition_id" => normalized_cond,
          "token_ids" => token_ids,
          "outcome_count" => length(data),
          # Subgraph doesn't have slug/question - would need Polymarket API
          "slug" => nil,
          "question" => nil
        }}

      {:ok, []} ->
        {:error, "No market data found for condition: #{condition_id}"}

      {:ok, nil} ->
        {:error, "No market data found for condition: #{condition_id}"}

      error ->
        error
    end
  end

  @doc """
  Get token ID to condition ID mapping from the orderbook subgraph.

  The `marketDatas` entity maps 256-bit token IDs to condition IDs (hex strings).
  This is essential for mapping trades back to markets.

  ## Parameters

  - `opts` - Keyword list of options:
    - `:limit` - Number of mappings (default: 100, max: 1000)
    - `:skip` - Pagination offset (default: 0)

  ## Returns

  - `{:ok, [%{token_id, condition_id, outcome_index}]}` - List of mappings
  - `{:error, reason}` - Error message
  """
  def get_market_data_mappings(opts \\ []) do
    limit = min(Keyword.get(opts, :limit, @default_limit), @max_limit)
    skip = Keyword.get(opts, :skip, 0)

    query = """
    {
      marketDatas(
        first: #{limit}
        skip: #{skip}
      ) {
        id
        condition
        outcomeIndex
      }
    }
    """

    case execute_query(@orderbook_subgraph, query, "marketDatas") do
      {:ok, data} ->
        mappings = Enum.map(data, fn item ->
          %{
            token_id: item["id"],
            condition_id: item["condition"],
            outcome_index: item["outcomeIndex"]
          }
        end)
        {:ok, mappings}

      error ->
        error
    end
  end

  @doc """
  Fetch all market data mappings with pagination.

  Builds a complete map of token_id -> condition_id for all known markets.

  ## Parameters

  - `opts` - Keyword list of options:
    - `:max_mappings` - Maximum mappings to fetch (default: 100_000)
    - `:progress_callback` - Function called with progress updates

  ## Returns

  - `{:ok, %{token_id => %{condition_id, outcome_index}}}` - Complete mapping
  - `{:error, reason}` - Error message
  """
  def build_subgraph_token_mapping(opts \\ []) do
    max_mappings = Keyword.get(opts, :max_mappings, 100_000)
    progress_callback = Keyword.get(opts, :progress_callback, fn _ -> :ok end)

    case fetch_all_with_pagination(
           fn skip ->
             get_market_data_mappings(skip: skip, limit: @max_limit)
           end,
           max_mappings,
           progress_callback
         ) do
      {:ok, mappings} ->
        map = Enum.reduce(mappings, %{}, fn item, acc ->
          Map.put(acc, item.token_id, %{
            condition_id: item.condition_id,
            outcome_index: item.outcome_index
          })
        end)
        {:ok, map}

      error ->
        error
    end
  end

  @doc """
  Get token ID to condition mapping from the positions subgraph.

  The `tokenIdConditions` entity maps the 256-bit token IDs to condition data.

  ## Parameters

  - `opts` - Keyword list of options:
    - `:limit` - Number of mappings (default: 100)
    - `:skip` - Pagination offset (default: 0)

  ## Returns

  - `{:ok, [mapping]}` - List of token-to-condition mappings
  - `{:error, reason}` - Error message
  """
  def get_token_id_conditions(opts \\ []) do
    limit = min(Keyword.get(opts, :limit, @default_limit), @max_limit)
    skip = Keyword.get(opts, :skip, 0)

    query = """
    {
      tokenIdConditions(
        first: #{limit}
        skip: #{skip}
      ) {
        id
      }
    }
    """

    execute_query(@positions_subgraph, query, "tokenIdConditions")
  end

  # ============================================
  # Subgraph Health & Metadata
  # ============================================

  @doc """
  Get metadata about a subgraph including sync status.

  ## Parameters

  - `subgraph` - Which subgraph to check: `:orderbook`, `:positions`, `:oi`, `:pnl`

  ## Returns

  - `{:ok, meta}` - Metadata map with sync status
  - `{:error, reason}` - Error message
  """
  def get_subgraph_meta(subgraph \\ :orderbook) do
    endpoint = subgraph_endpoint(subgraph)

    query = """
    {
      _meta {
        block {
          number
          timestamp
        }
        hasIndexingErrors
      }
    }
    """

    execute_query(endpoint, query, "_meta")
  end

  @doc """
  Check if the subgraph is synced and healthy.

  Returns `{:ok, true}` if synced within last hour, `{:ok, false}` otherwise.
  """
  def subgraph_healthy?(subgraph \\ :orderbook) do
    case get_subgraph_meta(subgraph) do
      {:ok, %{"block" => %{"timestamp" => ts}, "hasIndexingErrors" => false}} ->
        # Check if synced within last hour
        block_time = parse_timestamp(ts)
        current_time = System.system_time(:second)
        {:ok, current_time - block_time < 3600}

      {:ok, %{"hasIndexingErrors" => true}} ->
        {:ok, false}

      error ->
        error
    end
  end

  defp parse_timestamp(ts) when is_integer(ts), do: ts
  defp parse_timestamp(ts) when is_binary(ts), do: String.to_integer(ts)

  # ============================================
  # Convenience Functions
  # ============================================

  @doc """
  Get trades for a specific wallet address.

  Searches both maker and taker fields.

  ## Parameters

  - `wallet_address` - The wallet address to search for
  - `opts` - Additional options (same as `get_all_order_filled_events/1`)
  """
  def get_wallet_trades(wallet_address, opts \\ []) do
    # Note: The Graph doesn't support OR queries easily, so we make two requests
    with {:ok, maker_trades} <- get_all_order_filled_events(Keyword.put(opts, :maker, wallet_address)),
         {:ok, taker_trades} <- get_all_order_filled_events(Keyword.put(opts, :taker, wallet_address)) do
      # Deduplicate by event ID
      all_trades =
        (maker_trades ++ taker_trades)
        |> Enum.uniq_by(& &1["id"])
        |> Enum.sort_by(& &1["timestamp"], :desc)

      {:ok, all_trades}
    end
  end

  @doc """
  Get trades for a specific token ID (market outcome).

  ## Parameters

  - `token_id` - The 256-bit condition token ID (as string)
  - `opts` - Additional options (same as `get_all_order_filled_events/1`)
  """
  def get_token_trades(token_id, opts \\ []) do
    opts
    |> Keyword.put(:token_id, token_id)
    |> get_all_order_filled_events()
  end

  # ============================================
  # Statistics & Analysis
  # ============================================

  @doc """
  Get trade statistics for a time range.

  Returns aggregate stats useful for pattern detection.
  """
  def get_trade_stats(from_timestamp, to_timestamp) do
    with {:ok, events} <- get_all_order_filled_events(
           from_timestamp: from_timestamp,
           to_timestamp: to_timestamp,
           max_events: 100_000
         ) do
      stats = %{
        total_trades: length(events),
        unique_makers: events |> Enum.map(& &1["maker"]) |> Enum.uniq() |> length(),
        unique_takers: events |> Enum.map(& &1["taker"]) |> Enum.uniq() |> length(),
        unique_tokens: events |> Enum.flat_map(fn e -> [e["makerAssetId"], e["takerAssetId"]] end) |> Enum.uniq() |> length(),
        time_range: %{
          from: from_timestamp,
          to: to_timestamp,
          hours: div(to_timestamp - from_timestamp, 3600)
        }
      }

      {:ok, stats}
    end
  end

  # ============================================
  # Private Functions
  # ============================================

  defp execute_query(endpoint, query, result_key) do
    Logger.debug("Subgraph query to #{endpoint}: #{String.slice(query, 0, 200)}...")

    body = Jason.encode!(%{query: query})

    case Req.post(endpoint,
           body: body,
           headers: [{"content-type", "application/json"}],
           receive_timeout: @default_timeout
         ) do
      {:ok, %{status: 200, body: %{"data" => data}}} ->
        {:ok, Map.get(data, result_key)}

      {:ok, %{status: 200, body: %{"errors" => errors}}} ->
        error_msg = errors |> Enum.map(& &1["message"]) |> Enum.join(", ")
        Logger.warning("Subgraph GraphQL error: #{error_msg}")
        {:error, "GraphQL error: #{error_msg}"}

      {:ok, %{status: 404}} ->
        {:error, "Subgraph not found - may have been deprecated"}

      {:ok, %{status: 429}} ->
        Logger.warning("Subgraph rate limited")
        {:error, "Rate limited - please wait before retrying"}

      {:ok, %{status: code, body: body}} ->
        Logger.warning("Subgraph returned #{code}: #{inspect(body)}")
        {:error, "Subgraph returned status #{code}"}

      {:error, exception} ->
        Logger.error("Subgraph request failed: #{inspect(exception)}")
        {:error, "HTTP request failed: #{inspect(exception)}"}
    end
  end

  defp fetch_all_with_pagination(fetch_fn, max_events, progress_callback, skip \\ 0, acc \\ []) do
    # Rate limiting
    if skip > 0, do: Process.sleep(@rate_limit_delay)

    case fetch_fn.(skip) do
      {:ok, events} when is_list(events) and length(events) > 0 ->
        new_acc = acc ++ events
        progress_callback.(%{fetched: length(new_acc), batch: length(events)})

        cond do
          length(new_acc) >= max_events ->
            {:ok, Enum.take(new_acc, max_events)}

          length(events) < @max_limit ->
            # Last page (fewer than max results)
            {:ok, new_acc}

          true ->
            # More pages available
            fetch_all_with_pagination(fetch_fn, max_events, progress_callback, skip + @max_limit, new_acc)
        end

      {:ok, []} ->
        {:ok, acc}

      {:error, _} = error when acc == [] ->
        error

      {:error, reason} ->
        # Return what we have if we fail mid-pagination
        Logger.warning("Pagination interrupted at #{length(acc)} events: #{reason}")
        {:ok, acc}
    end
  end

  defp build_where_clause([]), do: ""
  defp build_where_clause(parts) do
    "where: { #{Enum.join(parts, ", ")} }"
  end

  defp add_timestamp_filter(parts, nil, nil), do: parts
  defp add_timestamp_filter(parts, from_ts, nil) when is_integer(from_ts) do
    parts ++ ["timestamp_gte: \"#{from_ts}\""]
  end
  defp add_timestamp_filter(parts, nil, to_ts) when is_integer(to_ts) do
    parts ++ ["timestamp_lte: \"#{to_ts}\""]
  end
  defp add_timestamp_filter(parts, from_ts, to_ts) when is_integer(from_ts) and is_integer(to_ts) do
    parts ++ ["timestamp_gte: \"#{from_ts}\"", "timestamp_lte: \"#{to_ts}\""]
  end

  defp add_token_filter(parts, nil), do: parts
  defp add_token_filter(parts, token_id) do
    # Search in both maker and taker asset IDs
    # Note: The Graph doesn't support OR, so this matches makerAssetId only
    # For full coverage, make separate queries for taker
    parts ++ ["makerAssetId: \"#{token_id}\""]
  end

  defp add_address_filter(parts, _field, nil), do: parts
  defp add_address_filter(parts, field, address) do
    # Normalize address to lowercase (The Graph stores lowercase)
    normalized = String.downcase(address)
    parts ++ ["#{field}: \"#{normalized}\""]
  end

  defp subgraph_endpoint(:orderbook), do: @orderbook_subgraph
  defp subgraph_endpoint(:positions), do: @positions_subgraph
  defp subgraph_endpoint(:oi), do: @oi_subgraph
  defp subgraph_endpoint(:pnl), do: @pnl_subgraph

  defp to_unix_timestamp(%DateTime{} = dt), do: DateTime.to_unix(dt)
  defp to_unix_timestamp(%Date{} = date) do
    date
    |> DateTime.new!(~T[00:00:00], "Etc/UTC")
    |> DateTime.to_unix()
  end
  defp to_unix_timestamp(ts) when is_integer(ts), do: ts
end
