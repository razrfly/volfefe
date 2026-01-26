defmodule VolfefeMachine.Polymarket do
  @moduledoc """
  Context module for Polymarket insider detection operations.

  Handles:
  - Market discovery and caching
  - Trade ingestion and storage
  - Wallet aggregation
  - Data synchronization from Polymarket APIs

  ## Architecture

  Data flows from Polymarket APIs through this context into local cache tables:

      gamma-api → sync_markets/1 → polymarket_markets
      data-api → ingest_trades/2 → polymarket_trades
                                  → polymarket_wallets (auto-created)

  ## Usage

      # Sync active markets
      {:ok, stats} = Polymarket.sync_markets()

      # Ingest trades for a market
      {:ok, stats} = Polymarket.ingest_market_trades(condition_id)

      # Get market by condition ID
      {:ok, market} = Polymarket.get_market_by_condition_id("0x123...")

      # Get wallet by address
      {:ok, wallet} = Polymarket.get_wallet("0xabc...")
  """

  import Ecto.Query
  require Logger

  alias VolfefeMachine.Repo
  alias VolfefeMachine.Polymarket.{
    Client, Market, Trade, Wallet, PatternBaseline, TradeScore,
    ConfirmedInsider, InsiderPattern, InvestigationCandidate, DiscoveryBatch,
    Alert, TradeMonitor
  }

  # ============================================
  # Market Operations
  # ============================================

  @doc """
  Sync markets from Polymarket gamma-api.

  Fetches active markets and upserts them into the local cache.

  ## Parameters

  - `opts` - Keyword list of options:
    - `:limit` - Markets per API call (default: 100)
    - `:max_markets` - Maximum markets to sync (default: 1000)
    - `:include_closed` - Include closed markets (default: false)

  ## Returns

  - `{:ok, %{inserted: n, updated: n, errors: n}}` - Sync statistics
  - `{:error, reason}` - If API call fails

  ## Examples

      {:ok, stats} = Polymarket.sync_markets()
      # => {:ok, %{inserted: 45, updated: 12, errors: 0}}
  """
  def sync_markets(opts \\ []) do
    limit = Keyword.get(opts, :limit, 100)
    max_markets = Keyword.get(opts, :max_markets, 1000)
    include_closed = Keyword.get(opts, :include_closed, false)

    Logger.info("Starting market sync (max: #{max_markets}, closed: #{include_closed})")

    case fetch_all_markets(limit, max_markets, include_closed) do
      {:ok, api_markets} ->
        results = Enum.map(api_markets, &upsert_market/1)

        stats = %{
          inserted: Enum.count(results, &match?({:ok, :inserted, _}, &1)),
          updated: Enum.count(results, &match?({:ok, :updated, _}, &1)),
          errors: Enum.count(results, &match?({:error, _}, &1))
        }

        Logger.info("Market sync complete: #{inspect(stats)}")
        {:ok, stats}

      {:error, reason} = error ->
        Logger.error("Market sync failed: #{reason}")
        error
    end
  end

  @doc """
  Get a market by its condition ID.

  ## Examples

      {:ok, market} = Polymarket.get_market_by_condition_id("0x123...")
      {:error, :not_found} = Polymarket.get_market_by_condition_id("invalid")
  """
  def get_market_by_condition_id(condition_id) do
    case Repo.get_by(Market, condition_id: condition_id) do
      nil -> {:error, :not_found}
      market -> {:ok, market}
    end
  end

  @doc """
  List markets with optional filters.

  ## Options

  - `:category` - Filter by category atom
  - `:is_active` - Filter by active status
  - `:is_event_based` - Filter by event-based flag
  - `:resolved` - Filter by resolution status (true/false)
  - `:limit` - Limit results (default: 100)
  - `:order_by` - Sort field (default: :volume_24hr)

  ## Examples

      # Active politics markets
      markets = Polymarket.list_markets(category: :politics, is_active: true)

      # Resolved event-based markets
      markets = Polymarket.list_markets(is_event_based: true, resolved: true)
  """
  def list_markets(opts \\ []) do
    limit = Keyword.get(opts, :limit, 100)
    order_by = Keyword.get(opts, :order_by, :volume_24hr)

    query =
      from(m in Market, order_by: [desc: field(m, ^order_by)], limit: ^limit)
      |> maybe_filter(:category, Keyword.get(opts, :category))
      |> maybe_filter(:is_active, Keyword.get(opts, :is_active))
      |> maybe_filter(:is_event_based, Keyword.get(opts, :is_event_based))
      |> maybe_filter_resolved(Keyword.get(opts, :resolved))

    Repo.all(query)
  end

  @doc """
  Count markets by category.

  Returns a map of category => count.

  ## Examples

      Polymarket.count_markets_by_category()
      # => %{politics: 45, corporate: 12, crypto: 89, ...}
  """
  def count_markets_by_category do
    from(m in Market,
      group_by: m.category,
      select: {m.category, count(m.id)}
    )
    |> Repo.all()
    |> Map.new()
  end

  # ============================================
  # Trade Operations
  # ============================================

  @doc """
  Ingest trades for a specific market.

  Fetches trades from the API and upserts them into the local cache.
  Automatically creates wallet records for new addresses.

  ## Parameters

  - `condition_id` - The market's condition ID
  - `opts` - Keyword list of options:
    - `:max_trades` - Maximum trades to fetch (default: 10_000)
    - `:page_size` - Trades per API call (default: 100)

  ## Returns

  - `{:ok, %{inserted: n, updated: n, errors: n, wallets_created: n}}` - Stats
  - `{:error, reason}` - If API call fails

  ## Examples

      {:ok, stats} = Polymarket.ingest_market_trades("0x123...")
  """
  def ingest_market_trades(condition_id, opts \\ []) do
    max_trades = Keyword.get(opts, :max_trades, 10_000)
    page_size = Keyword.get(opts, :page_size, 100)

    Logger.info("Ingesting trades for market #{condition_id} (max: #{max_trades})")

    # Ensure market exists in our cache
    market = ensure_market_cached(condition_id)

    case Client.get_all_market_trades(condition_id, max_trades: max_trades, page_size: page_size) do
      {:ok, api_trades} ->
        results = Enum.map(api_trades, fn trade_data ->
          upsert_trade(trade_data, market)
        end)

        stats = %{
          inserted: Enum.count(results, &match?({:ok, :inserted, _}, &1)),
          updated: Enum.count(results, &match?({:ok, :updated, _}, &1)),
          errors: Enum.count(results, &match?({:error, _}, &1)),
          wallets_created: count_new_wallets(results)
        }

        Logger.info("Trade ingestion complete for #{condition_id}: #{inspect(stats)}")
        {:ok, stats}

      {:error, reason} = error ->
        Logger.error("Trade ingestion failed for #{condition_id}: #{reason}")
        error
    end
  end

  @doc """
  Ingest recent trades across all markets.

  ## Parameters

  - `opts` - Keyword list of options:
    - `:limit` - Trades to fetch (default: 1000)

  ## Returns

  - `{:ok, %{inserted: n, updated: n, errors: n}}` - Stats
  """
  def ingest_recent_trades(opts \\ []) do
    limit = Keyword.get(opts, :limit, 1000)

    Logger.info("Ingesting #{limit} recent trades")

    case Client.get_trades(limit: limit) do
      {:ok, api_trades} ->
        results = Enum.map(api_trades, fn trade_data ->
          market = ensure_market_cached(trade_data["conditionId"])
          upsert_trade(trade_data, market)
        end)

        stats = %{
          inserted: Enum.count(results, &match?({:ok, :inserted, _}, &1)),
          updated: Enum.count(results, &match?({:ok, :updated, _}, &1)),
          errors: Enum.count(results, &match?({:error, _}, &1))
        }

        Logger.info("Recent trade ingestion complete: #{inspect(stats)}")
        {:ok, stats}

      {:error, reason} = error ->
        Logger.error("Recent trade ingestion failed: #{reason}")
        error
    end
  end

  @doc """
  Ingest recent trades via blockchain subgraph (Goldsky).

  This is the primary ingestion method that works reliably.
  Uses the SubgraphClient with proper rate limiting.

  ## Options

  - `:limit` - Maximum trades to fetch (default: 2000)
  - `:hours` - How many hours back to fetch (default: 24)

  ## Returns

  - `{:ok, %{inserted: n, updated: n, errors: n, unmapped: n}}`
  - `{:error, :rate_limited}` - Rate limited, caller should retry later
  - `{:error, reason}` - Other error
  """
  def ingest_trades_via_subgraph(opts \\ []) do
    alias VolfefeMachine.Polymarket.{SubgraphClient, TokenMapping}

    limit = Keyword.get(opts, :limit, 2000)
    hours = Keyword.get(opts, :hours, 24)
    build_subgraph_mapping = Keyword.get(opts, :build_subgraph_mapping, true)

    Logger.info("[Subgraph Ingest] Starting: limit=#{limit}, hours=#{hours}")

    # Calculate time range
    to_ts = DateTime.utc_now() |> DateTime.to_unix()
    from_ts = to_ts - (hours * 3600)

    # Build token mapping from local DB
    {:ok, local_mapping} = TokenMapping.build_mapping(include_inactive: true)
    Logger.info("[Subgraph Ingest] Local token mapping: #{map_size(local_mapping)} tokens")

    # Optionally build subgraph token mapping for better coverage
    # This increases mapping coverage from ~2% to ~80%+
    subgraph_mapping = if build_subgraph_mapping do
      case SubgraphClient.build_subgraph_token_mapping(max_mappings: 30_000) do
        {:ok, mapping} ->
          Logger.info("[Subgraph Ingest] Subgraph token mapping: #{map_size(mapping)} tokens")
          mapping
        {:error, reason} ->
          Logger.warning("[Subgraph Ingest] Failed to build subgraph mapping: #{inspect(reason)}")
          %{}
      end
    else
      %{}
    end

    combined_mapping = {local_mapping, subgraph_mapping}
    total_tokens = map_size(local_mapping) + map_size(subgraph_mapping)
    Logger.info("[Subgraph Ingest] Combined mapping: #{total_tokens} tokens")

    # Fetch events from subgraph
    case SubgraphClient.get_order_filled_events(
           from_timestamp: from_ts,
           to_timestamp: to_ts,
           limit: limit
         ) do
      {:ok, events} ->
        Logger.info("[Subgraph Ingest] Fetched #{length(events)} events")
        stats = process_subgraph_events(events, combined_mapping)
        Logger.info("[Subgraph Ingest] Complete: #{inspect(stats)}")
        {:ok, stats}

      {:error, :rate_limited} = error ->
        Logger.warning("[Subgraph Ingest] Rate limited by subgraph")
        error

      {:error, reason} = error ->
        Logger.error("[Subgraph Ingest] Failed: #{inspect(reason)}")
        error
    end
  end

  # Process subgraph events into trades
  # combined_mapping is a tuple {local_mapping, subgraph_mapping}
  defp process_subgraph_events(events, combined_mapping) do
    alias VolfefeMachine.Polymarket.TokenMapping
    {local_mapping, subgraph_mapping} = combined_mapping

    results = Enum.map(events, fn event ->
      # Determine which token ID to use (non-zero asset)
      maker_asset = event["makerAssetId"]
      taker_asset = event["takerAssetId"]

      # Determine which token ID to use and trade semantics:
      # - maker_asset != "0": maker is SELLING their position token
      # - taker_asset != "0": taker is BUYING with their position token (giving token to maker)
      {token_id, side, wallet_address, token_is_maker} = cond do
        maker_asset != "0" -> {maker_asset, "SELL", event["maker"], true}
        taker_asset != "0" -> {taker_asset, "BUY", event["taker"], false}
        true -> {maker_asset, "SELL", event["maker"], true}
      end

      # Look up market from combined mapping (local first, then subgraph, then auto-create)
      mapping_result = case TokenMapping.lookup(local_mapping, token_id) do
        {:ok, info} -> {:ok, info}
        :not_found ->
          # Try subgraph mapping
          case Map.get(subgraph_mapping, token_id) do
            %{condition_id: cond_id, outcome_index: out_idx} ->
              # Find or create market from condition_id
              case find_or_create_market_id(cond_id) do
                nil -> :not_found
                market_id -> {:ok, %{market_id: market_id, condition_id: cond_id, outcome_index: out_idx || 0}}
              end
            nil ->
              # No mapping found - auto-create stub market from token_id
              # Use token_id as synthetic condition_id (allows tracking trades)
              synthetic_cond_id = "token_#{String.slice(token_id, 0..31)}"
              case find_or_create_market_from_token(synthetic_cond_id, token_id) do
                nil -> :not_found
                market_id -> {:ok, %{market_id: market_id, condition_id: synthetic_cond_id, outcome_index: 0}}
              end
          end
      end

      case mapping_result do
        {:ok, %{market_id: market_id, condition_id: condition_id, outcome_index: outcome_index}} ->
          insert_subgraph_trade(event, %{
            market_id: market_id,
            condition_id: condition_id,
            outcome_index: outcome_index,
            side: side,
            wallet_address: wallet_address,
            token_is_maker: token_is_maker
          })

        :not_found ->
          :unmapped
      end
    end)

    %{
      inserted: Enum.count(results, &(&1 == :inserted)),
      updated: Enum.count(results, &(&1 == :updated)),
      errors: Enum.count(results, &(&1 == :error)),
      unmapped: Enum.count(results, &(&1 == :unmapped))
    }
  end

  # Find or create market by condition_id
  # Creates a minimal "stub" market if one doesn't exist, allowing trade tracking
  defp find_or_create_market_id(condition_id) when is_binary(condition_id) do
    import Ecto.Query
    alias VolfefeMachine.Polymarket.Market

    case Repo.one(from m in Market, where: m.condition_id == ^condition_id, select: m.id, limit: 1) do
      nil ->
        # Create a minimal stub market for trade tracking
        # This allows us to ingest trades even without full market metadata
        attrs = %{
          condition_id: condition_id,
          question: "[Pending Discovery] condition: #{String.slice(condition_id, 0..15)}...",
          outcomes: %{"options" => ["Yes", "No"]},
          outcome_prices: %{"Yes" => "0.5", "No" => "0.5"},
          category: :other,
          is_active: true,
          meta: %{
            source: "subgraph_discovery",
            discovered_at: DateTime.utc_now() |> DateTime.to_iso8601(),
            needs_metadata: true
          }
        }

        case %Market{} |> Market.changeset(attrs) |> Repo.insert() do
          {:ok, market} ->
            Logger.debug("[Market Discovery] Created stub market for #{String.slice(condition_id, 0..15)}...")
            market.id
          {:error, _changeset} ->
            # Race condition - another process created it, try lookup again
            Repo.one(from m in Market, where: m.condition_id == ^condition_id, select: m.id, limit: 1)
        end

      market_id ->
        market_id
    end
  end

  # Find or create market from token_id (when no condition_id mapping exists)
  # Creates a stub market to allow trade tracking even without market metadata
  defp find_or_create_market_from_token(synthetic_cond_id, token_id) when is_binary(synthetic_cond_id) do
    import Ecto.Query
    alias VolfefeMachine.Polymarket.Market

    case Repo.one(from m in Market, where: m.condition_id == ^synthetic_cond_id, select: m.id, limit: 1) do
      nil ->
        attrs = %{
          condition_id: synthetic_cond_id,
          question: "[Unknown Market] token: #{String.slice(token_id, 0..15)}...",
          outcomes: %{"options" => ["Yes", "No"]},
          outcome_prices: %{"Yes" => "0.5", "No" => "0.5"},
          category: :other,
          is_active: true,
          meta: %{
            source: "token_discovery",
            token_id: token_id,
            discovered_at: DateTime.utc_now() |> DateTime.to_iso8601(),
            needs_metadata: true,
            needs_condition_mapping: true
          }
        }

        case %Market{} |> Market.changeset(attrs) |> Repo.insert() do
          {:ok, market} ->
            Logger.debug("[Token Discovery] Created stub market for token #{String.slice(token_id, 0..15)}...")
            market.id
          {:error, _changeset} ->
            Repo.one(from m in Market, where: m.condition_id == ^synthetic_cond_id, select: m.id, limit: 1)
        end

      market_id ->
        market_id
    end
  end

  # Insert a single trade from subgraph event
  defp insert_subgraph_trade(event, mapping) do
    tx_hash = event["id"]

    # Check if already exists
    case Repo.get_by(Trade, transaction_hash: tx_hash) do
      nil ->
        # Parse timestamp
        timestamp = event["timestamp"]
        |> String.to_integer()
        |> DateTime.from_unix!()

        # Calculate amounts (divide by 10^6 for USDC decimals)
        maker_amount = parse_subgraph_amount(event["makerAmountFilled"])
        taker_amount = parse_subgraph_amount(event["takerAmountFilled"])

        # Determine size and price based on which asset is the market token
        {size, usdc_size, price} = if mapping.token_is_maker do
          s = maker_amount
          u = taker_amount
          p = if Decimal.compare(s, 0) == :gt, do: Decimal.div(u, s), else: Decimal.new(0)
          {s, u, p}
        else
          s = taker_amount
          u = maker_amount
          p = if Decimal.compare(s, 0) == :gt, do: Decimal.div(u, s), else: Decimal.new(0)
          {s, u, p}
        end

        outcome = if mapping.outcome_index == 0, do: "Yes", else: "No"

        # Ensure wallet exists
        {:ok, wallet} = get_or_create_wallet(mapping.wallet_address, %{})

        attrs = %{
          transaction_hash: tx_hash,
          wallet_id: wallet.id,
          wallet_address: mapping.wallet_address,
          condition_id: mapping.condition_id,
          market_id: mapping.market_id,
          side: mapping.side,
          outcome: outcome,
          outcome_index: mapping.outcome_index,
          size: size,
          price: Decimal.round(price, 4),
          usdc_size: usdc_size,
          trade_timestamp: timestamp,
          meta: %{
            source: "subgraph",
            maker: event["maker"],
            taker: event["taker"],
            makerAssetId: event["makerAssetId"],
            takerAssetId: event["takerAssetId"]
          }
        }

        case %Trade{} |> Trade.changeset(attrs) |> Repo.insert() do
          {:ok, _trade} -> :inserted
          {:error, _changeset} -> :error
        end

      _existing ->
        :updated
    end
  end

  defp parse_subgraph_amount(nil), do: Decimal.new(0)
  defp parse_subgraph_amount(amount) when is_binary(amount) do
    # Subgraph amounts are in wei (10^6 for USDC)
    case Decimal.parse(amount) do
      {decimal, ""} -> Decimal.div(decimal, Decimal.new(1_000_000))
      _ -> Decimal.new(0)
    end
  end
  defp parse_subgraph_amount(amount) when is_integer(amount) do
    Decimal.div(Decimal.new(amount), Decimal.new(1_000_000))
  end

  @doc """
  Get trades for a market with optional filters.

  ## Options

  - `:wallet_address` - Filter by wallet
  - `:side` - Filter by "BUY" or "SELL"
  - `:outcome` - Filter by "Yes" or "No"
  - `:limit` - Limit results (default: 100)
  - `:order_by` - Sort field (default: :trade_timestamp)

  ## Examples

      trades = Polymarket.list_trades(market_id: 123, side: "BUY")
  """
  def list_trades(opts \\ []) do
    limit = Keyword.get(opts, :limit, 100)
    order_by = Keyword.get(opts, :order_by, :trade_timestamp)

    query =
      from(t in Trade, order_by: [desc: field(t, ^order_by)], limit: ^limit)
      |> maybe_filter(:market_id, Keyword.get(opts, :market_id))
      |> maybe_filter(:wallet_address, Keyword.get(opts, :wallet_address))
      |> maybe_filter(:side, Keyword.get(opts, :side))
      |> maybe_filter(:outcome, Keyword.get(opts, :outcome))

    Repo.all(query)
  end

  # ============================================
  # Wallet Operations
  # ============================================

  @doc """
  Get or create a wallet by address.

  ## Examples

      {:ok, wallet} = Polymarket.get_or_create_wallet("0x123...")
  """
  def get_or_create_wallet(address, attrs \\ %{}) do
    case Repo.get_by(Wallet, address: address) do
      nil ->
        %Wallet{}
        |> Wallet.changeset(Map.put(attrs, :address, address))
        |> Repo.insert()

      wallet ->
        {:ok, wallet}
    end
  end

  @doc """
  Get a wallet by address.

  ## Examples

      {:ok, wallet} = Polymarket.get_wallet("0x123...")
      {:error, :not_found} = Polymarket.get_wallet("invalid")
  """
  def get_wallet(address) do
    case Repo.get_by(Wallet, address: address) do
      nil -> {:error, :not_found}
      wallet -> {:ok, wallet}
    end
  end

  @doc """
  Update wallet aggregates from trades.

  Recalculates total_trades, total_volume, wins, losses, etc.

  ## Parameters

  - `wallet` - Wallet struct or address string

  ## Returns

  - `{:ok, wallet}` - Updated wallet
  - `{:error, changeset}` - If update fails
  """
  def update_wallet_aggregates(wallet_or_address) do
    wallet =
      case wallet_or_address do
        %Wallet{} = w -> w
        address when is_binary(address) ->
          case get_wallet(address) do
            {:ok, w} -> w
            {:error, :not_found} -> nil
          end
      end

    if wallet do
      aggregates = calculate_wallet_aggregates(wallet.address)

      wallet
      |> Wallet.aggregates_changeset(aggregates)
      |> Repo.update()
    else
      {:error, :wallet_not_found}
    end
  end

  @doc """
  List wallets with optional filters.

  ## Options

  - `:min_trades` - Minimum trade count
  - `:min_win_rate` - Minimum win rate (decimal 0-1)
  - `:limit` - Limit results (default: 100)
  - `:order_by` - Sort field (default: :total_trades)

  ## Examples

      # Active traders with high win rates
      wallets = Polymarket.list_wallets(min_trades: 10, min_win_rate: 0.7)
  """
  def list_wallets(opts \\ []) do
    limit = Keyword.get(opts, :limit, 100)
    order_by = Keyword.get(opts, :order_by, :total_trades)
    min_trades = Keyword.get(opts, :min_trades)
    min_win_rate = Keyword.get(opts, :min_win_rate)

    query =
      from(w in Wallet, order_by: [desc: field(w, ^order_by)], limit: ^limit)
      |> maybe_filter_gte(:total_trades, min_trades)
      |> maybe_filter_gte(:win_rate, min_win_rate)

    Repo.all(query)
  end

  # ============================================
  # Private Functions
  # ============================================

  defp fetch_all_markets(page_size, max_markets, include_closed, offset \\ 0, acc \\ []) do
    if length(acc) >= max_markets do
      {:ok, Enum.take(acc, max_markets)}
    else
      case Client.get_markets(limit: page_size, offset: offset, closed: include_closed) do
        {:ok, markets} when is_list(markets) and length(markets) > 0 ->
          new_acc = acc ++ markets

          if length(markets) < page_size do
            {:ok, Enum.take(new_acc, max_markets)}
          else
            fetch_all_markets(page_size, max_markets, include_closed, offset + page_size, new_acc)
          end

        {:ok, []} ->
          {:ok, acc}

        {:error, _} = error ->
          if acc == [] do
            error
          else
            Logger.warning("Pagination interrupted, returning #{length(acc)} markets")
            {:ok, acc}
          end
      end
    end
  end

  defp upsert_market(api_market) do
    condition_id = api_market["conditionId"] || api_market["condition_id"]

    attrs = %{
      condition_id: condition_id,
      question: api_market["question"],
      description: api_market["description"],
      slug: api_market["slug"],
      outcomes: parse_outcomes(api_market),
      outcome_prices: parse_outcome_prices(api_market),
      end_date: parse_datetime(api_market["endDate"]),
      resolution_date: parse_datetime(api_market["resolutionDate"]),
      resolved_outcome: api_market["resolvedOutcome"],
      volume: parse_decimal(api_market["volume"]),
      volume_24hr: parse_decimal(api_market["volume24hr"]),
      liquidity: parse_decimal(api_market["liquidity"]),
      category: Market.categorize_from_question(api_market["question"] || ""),
      is_active: api_market["active"] != false && api_market["closed"] != true,
      meta: api_market,
      last_synced_at: DateTime.utc_now()
    }

    case Repo.get_by(Market, condition_id: condition_id) do
      nil ->
        case %Market{} |> Market.changeset(attrs) |> Repo.insert() do
          {:ok, market} -> {:ok, :inserted, market}
          {:error, changeset} -> {:error, changeset}
        end

      existing ->
        case existing |> Market.changeset(attrs) |> Repo.update() do
          {:ok, market} -> {:ok, :updated, market}
          {:error, changeset} -> {:error, changeset}
        end
    end
  end

  defp upsert_trade(api_trade, market) do
    transaction_hash = api_trade["transactionHash"]
    wallet_address = api_trade["proxyWallet"]

    # Ensure wallet exists
    {:ok, wallet} = get_or_create_wallet(wallet_address, %{
      pseudonym: api_trade["pseudonym"],
      display_name: api_trade["name"]
    })

    trade_timestamp = parse_timestamp(api_trade["timestamp"])

    # Calculate wallet age at time of trade (days between wallet first seen and trade)
    wallet_age_days = calculate_wallet_age_at_trade(wallet, trade_timestamp)

    # Use wallet's current trade count as activity proxy
    wallet_trade_count = wallet.total_trades || 0

    attrs = %{
      transaction_hash: transaction_hash,
      market_id: if(market, do: market.id, else: nil),
      wallet_id: wallet.id,
      wallet_address: wallet_address,
      condition_id: api_trade["conditionId"],
      side: String.upcase(to_string(api_trade["side"])),
      outcome: api_trade["outcome"],
      outcome_index: api_trade["outcomeIndex"],
      size: parse_decimal(api_trade["size"]),
      price: parse_decimal(api_trade["price"]),
      usdc_size: parse_decimal(api_trade["usdcSize"]),
      trade_timestamp: trade_timestamp,
      price_extremity: calculate_price_extremity(api_trade["price"]),
      wallet_age_days: wallet_age_days,
      wallet_trade_count: wallet_trade_count,
      meta: api_trade
    }

    case Repo.get_by(Trade, transaction_hash: transaction_hash) do
      nil ->
        case %Trade{} |> Trade.changeset(attrs) |> Repo.insert() do
          {:ok, trade} -> {:ok, :inserted, trade, wallet}
          {:error, changeset} -> {:error, changeset}
        end

      existing ->
        case existing |> Trade.changeset(attrs) |> Repo.update() do
          {:ok, trade} -> {:ok, :updated, trade, wallet}
          {:error, changeset} -> {:error, changeset}
        end
    end
  end

  defp ensure_market_cached(condition_id) do
    case get_market_by_condition_id(condition_id) do
      {:ok, market} -> market
      {:error, :not_found} ->
        # Try to fetch from API
        case Client.get_market(condition_id) do
          {:ok, api_market} ->
            case upsert_market(api_market) do
              {:ok, _, market} -> market
              {:error, _} -> nil
            end
          {:error, _} -> nil
        end
    end
  end

  defp calculate_wallet_aggregates(address) do
    trades_query =
      from(t in Trade,
        where: t.wallet_address == ^address,
        select: %{
          total_trades: count(t.id),
          total_volume: sum(t.usdc_size),
          first_seen: min(t.trade_timestamp),
          last_seen: max(t.trade_timestamp)
        }
      )

    results_query =
      from(t in Trade,
        where: t.wallet_address == ^address and not is_nil(t.was_correct),
        select: %{
          resolved: count(t.id),
          wins: sum(fragment("CASE WHEN ? THEN 1 ELSE 0 END", t.was_correct)),
          losses: sum(fragment("CASE WHEN NOT ? THEN 1 ELSE 0 END", t.was_correct))
        }
      )

    markets_query =
      from(t in Trade,
        where: t.wallet_address == ^address,
        select: count(t.condition_id, :distinct)
      )

    trade_stats = Repo.one(trades_query) || %{}
    result_stats = Repo.one(results_query) || %{}
    unique_markets = Repo.one(markets_query) || 0

    wins = result_stats[:wins] || 0
    losses = result_stats[:losses] || 0

    %{
      total_trades: trade_stats[:total_trades] || 0,
      total_volume: trade_stats[:total_volume] || Decimal.new(0),
      unique_markets: unique_markets,
      first_seen_at: trade_stats[:first_seen],
      last_seen_at: trade_stats[:last_seen],
      resolved_positions: result_stats[:resolved] || 0,
      wins: wins,
      losses: losses,
      win_rate: Wallet.calculate_win_rate(wins, losses),
      last_aggregated_at: DateTime.utc_now()
    }
  end

  defp count_new_wallets(results) do
    results
    |> Enum.filter(&match?({:ok, :inserted, _, _}, &1))
    |> Enum.map(fn {:ok, :inserted, _, wallet} -> wallet.id end)
    |> Enum.uniq()
    |> length()
  end

  # Calculate wallet age in days at the time of trade
  # Returns 0 for brand new wallets, nil if timestamps can't be compared
  defp calculate_wallet_age_at_trade(_wallet, nil), do: nil
  defp calculate_wallet_age_at_trade(%{first_seen_at: nil}, _trade_timestamp), do: 0
  defp calculate_wallet_age_at_trade(%{first_seen_at: first_seen}, trade_timestamp) do
    # Days between wallet's first trade and this trade
    case DateTime.diff(trade_timestamp, first_seen, :day) do
      days when days < 0 -> 0  # Trade is before first_seen (shouldn't happen, but handle gracefully)
      days -> days
    end
  end

  defp parse_outcomes(api_market) do
    case api_market["outcomes"] do
      list when is_list(list) -> %{"options" => list}
      str when is_binary(str) ->
        case Jason.decode(str) do
          {:ok, list} -> %{"options" => list}
          _ -> %{"options" => ["Yes", "No"]}
        end
      _ -> %{"options" => ["Yes", "No"]}
    end
  end

  defp parse_outcome_prices(api_market) do
    case api_market["outcomePrices"] do
      str when is_binary(str) ->
        case Jason.decode(str) do
          {:ok, prices} -> %{"prices" => prices}
          _ -> nil
        end
      list when is_list(list) -> %{"prices" => list}
      _ -> nil
    end
  end

  defp parse_datetime(nil), do: nil
  defp parse_datetime(str) when is_binary(str) do
    case DateTime.from_iso8601(str) do
      {:ok, dt, _offset} -> dt
      _ -> nil
    end
  end
  defp parse_datetime(_), do: nil

  defp parse_timestamp(nil), do: nil
  defp parse_timestamp(ts) when is_integer(ts) do
    DateTime.from_unix!(ts)
  end
  defp parse_timestamp(ts) when is_binary(ts) do
    ts |> String.to_integer() |> DateTime.from_unix!()
  end

  defp parse_decimal(nil), do: nil
  defp parse_decimal(val) when is_number(val), do: Decimal.from_float(val * 1.0)
  defp parse_decimal(val) when is_binary(val), do: Decimal.new(val)

  defp calculate_price_extremity(nil), do: nil
  defp calculate_price_extremity(price) when is_number(price) do
    Decimal.from_float(abs(price - 0.5))
  end

  defp maybe_filter(query, _field, nil), do: query
  defp maybe_filter(query, field, value) do
    from(q in query, where: field(q, ^field) == ^value)
  end

  defp maybe_filter_gte(query, _field, nil), do: query
  defp maybe_filter_gte(query, field, value) do
    from(q in query, where: field(q, ^field) >= ^value)
  end

  defp maybe_filter_resolved(query, nil), do: query
  defp maybe_filter_resolved(query, true) do
    from(q in query, where: not is_nil(q.resolved_outcome))
  end
  defp maybe_filter_resolved(query, false) do
    from(q in query, where: is_nil(q.resolved_outcome))
  end

  # ============================================
  # Phase 2: Historical Backfill
  # ============================================

  @doc """
  Sync resolved (closed) markets from Polymarket.

  Fetches closed markets and determines resolution from outcome prices.
  Markets with outcome prices of ["1", "0"] resolved to "Yes",
  prices of ["0", "1"] resolved to "No".

  ## Parameters

  - `opts` - Keyword list of options:
    - `:max_markets` - Maximum markets to sync (default: 500)
    - `:category_filter` - Filter to specific category (optional)

  ## Returns

  - `{:ok, %{synced: n, resolved: n, event_based: n}}` - Stats
  """
  def sync_resolved_markets(opts \\ []) do
    max_markets = Keyword.get(opts, :max_markets, 500)
    category_filter = Keyword.get(opts, :category_filter)

    Logger.info("Syncing resolved markets (max: #{max_markets})")

    case fetch_all_markets(100, max_markets, true) do
      {:ok, api_markets} ->
        # Filter to closed markets only
        closed_markets = Enum.filter(api_markets, fn m -> m["closed"] == true end)

        results = Enum.map(closed_markets, fn api_market ->
          # Parse resolved_outcome from outcomePrices
          resolved_outcome = determine_resolved_outcome(api_market)
          api_market_with_resolution = Map.put(api_market, "resolvedOutcome", resolved_outcome)
          upsert_market(api_market_with_resolution)
        end)

        synced_markets =
          results
          |> Enum.filter(&match?({:ok, _, _}, &1))
          |> Enum.map(fn {:ok, _, m} -> m end)

        resolved_count = Enum.count(synced_markets, & &1.resolved_outcome)
        event_based_count = Enum.count(synced_markets, & &1.is_event_based)

        # Apply category filter if specified
        final_markets = if category_filter do
          Enum.filter(synced_markets, & &1.category == category_filter)
        else
          synced_markets
        end

        stats = %{
          synced: length(synced_markets),
          resolved: resolved_count,
          event_based: event_based_count,
          filtered: length(final_markets)
        }

        Logger.info("Resolved market sync complete: #{inspect(stats)}")
        {:ok, stats}

      {:error, reason} = error ->
        Logger.error("Resolved market sync failed: #{reason}")
        error
    end
  end

  @doc """
  Backfill trades for all resolved event-based markets.

  This is the main entry point for Phase 2 historical backfill.

  ## Parameters

  - `opts` - Keyword list of options:
    - `:max_markets` - Maximum markets to process (default: 100)
    - `:max_trades_per_market` - Max trades per market (default: 10_000)
    - `:categories` - List of categories to include (default: event-based)

  ## Returns

  - `{:ok, %{markets: n, trades: n, wallets: n}}` - Aggregate stats
  """
  def backfill_historical_trades(opts \\ []) do
    max_markets = Keyword.get(opts, :max_markets, 100)
    max_trades = Keyword.get(opts, :max_trades_per_market, 10_000)
    categories = Keyword.get(opts, :categories, [:politics, :corporate, :legal])

    Logger.info("Starting historical backfill for #{max_markets} markets")

    # Get resolved event-based markets
    markets =
      from(m in Market,
        where: not is_nil(m.resolved_outcome) and m.category in ^categories,
        order_by: [desc: m.volume],
        limit: ^max_markets
      )
      |> Repo.all()

    Logger.info("Found #{length(markets)} resolved markets to backfill")

    # Process each market
    results = Enum.map(markets, fn market ->
      Logger.info("Backfilling trades for: #{String.slice(market.question, 0, 50)}...")

      case ingest_market_trades(market.condition_id, max_trades: max_trades) do
        {:ok, stats} ->
          # Calculate outcomes for this market's trades
          calculate_trade_outcomes(market)
          {:ok, market, stats}

        {:error, reason} ->
          Logger.warning("Failed to backfill #{market.condition_id}: #{reason}")
          {:error, market, reason}
      end
    end)

    # Aggregate stats
    successful = Enum.filter(results, &match?({:ok, _, _}, &1))
    total_trades = Enum.sum(Enum.map(successful, fn {:ok, _, s} -> s.inserted + s.updated end))
    total_wallets = Enum.sum(Enum.map(successful, fn {:ok, _, s} -> s.wallets_created end))

    stats = %{
      markets_processed: length(successful),
      markets_failed: length(results) - length(successful),
      total_trades: total_trades,
      wallets_created: total_wallets
    }

    Logger.info("Historical backfill complete: #{inspect(stats)}")
    {:ok, stats}
  end

  @doc """
  Calculate was_correct and profit_loss for trades in a resolved market.

  ## Parameters

  - `market` - Market struct with resolved_outcome set

  ## Returns

  - `{:ok, %{updated: n}}` - Number of trades updated
  """
  def calculate_trade_outcomes(%Market{resolved_outcome: nil}), do: {:ok, %{updated: 0}}

  def calculate_trade_outcomes(%Market{} = market) do
    # Get all trades for this market
    trades =
      from(t in Trade,
        where: t.market_id == ^market.id and is_nil(t.was_correct)
      )
      |> Repo.all()

    updated_count =
      trades
      |> Enum.map(fn trade ->
        was_correct = determine_trade_correctness(trade, market)
        profit_loss = Trade.estimate_profit_loss(trade.side, trade.size, trade.price, was_correct)

        # Also calculate hours_before_resolution if we have resolution date
        hours_before = if market.end_date do
          Trade.calculate_hours_before_resolution(trade.trade_timestamp, market.end_date)
        else
          nil
        end

        trade
        |> Trade.metrics_changeset(%{
          was_correct: was_correct,
          profit_loss: profit_loss,
          hours_before_resolution: hours_before
        })
        |> Repo.update()
      end)
      |> Enum.count(&match?({:ok, _}, &1))

    {:ok, %{updated: updated_count}}
  end

  @doc """
  Calculate outcomes for all resolved markets' trades.

  ## Returns

  - `{:ok, %{markets: n, trades: n}}` - Stats
  """
  def calculate_all_trade_outcomes do
    markets =
      from(m in Market, where: not is_nil(m.resolved_outcome))
      |> Repo.all()

    Logger.info("Calculating outcomes for #{length(markets)} resolved markets")

    results = Enum.map(markets, fn market ->
      {:ok, stats} = calculate_trade_outcomes(market)
      stats.updated
    end)

    total_updated = Enum.sum(results)

    Logger.info("Updated outcomes for #{total_updated} trades")
    {:ok, %{markets: length(markets), trades: total_updated}}
  end

  @doc """
  Update aggregates for all wallets with trades.

  ## Returns

  - `{:ok, %{updated: n}}` - Number of wallets updated
  """
  def update_all_wallet_aggregates do
    # Get all wallet addresses with trades
    addresses =
      from(t in Trade, select: t.wallet_address, distinct: true)
      |> Repo.all()

    Logger.info("Updating aggregates for #{length(addresses)} wallets")

    updated =
      addresses
      |> Enum.map(&update_wallet_aggregates/1)
      |> Enum.count(&match?({:ok, _}, &1))

    Logger.info("Updated #{updated} wallet aggregates")
    {:ok, %{updated: updated}}
  end

  @doc """
  Get backfill statistics.

  Returns counts of markets, trades, and wallets by various criteria.
  """
  def backfill_stats do
    total_markets = Repo.aggregate(Market, :count)
    resolved_markets = Repo.aggregate(from(m in Market, where: not is_nil(m.resolved_outcome)), :count)

    total_trades = Repo.aggregate(Trade, :count)
    scored_trades = Repo.aggregate(from(t in Trade, where: not is_nil(t.was_correct)), :count)
    winning_trades = Repo.aggregate(from(t in Trade, where: t.was_correct == true), :count)

    total_wallets = Repo.aggregate(Wallet, :count)

    category_breakdown =
      from(m in Market,
        where: not is_nil(m.resolved_outcome),
        group_by: m.category,
        select: {m.category, count(m.id)}
      )
      |> Repo.all()
      |> Map.new()

    %{
      markets: %{
        total: total_markets,
        resolved: resolved_markets,
        by_category: category_breakdown
      },
      trades: %{
        total: total_trades,
        with_outcomes: scored_trades,
        winning: winning_trades,
        win_rate: if(scored_trades > 0, do: Float.round(winning_trades / scored_trades, 4), else: 0)
      },
      wallets: %{
        total: total_wallets
      }
    }
  end

  @doc """
  Backfill wallet_age_days and wallet_trade_count for all existing trades.

  Calculates:
  - wallet_age_days: Days between wallet's first trade and this trade
  - wallet_trade_count: Wallet's total trades at time of trade (uses current count as proxy)

  ## Options

  - `:batch_size` - Trades to process per batch (default: 500)
  - `:dry_run` - If true, report what would be updated without updating (default: false)

  ## Returns

  - `{:ok, %{updated: n, errors: n, skipped: n}}`
  """
  def backfill_wallet_signals(opts \\ []) do
    batch_size = Keyword.get(opts, :batch_size, 500)
    dry_run = Keyword.get(opts, :dry_run, false)

    # Build a map of wallet first_seen_at timestamps and trade counts
    wallets_map =
      from(w in Wallet,
        select: {w.address, %{first_seen_at: w.first_seen_at, total_trades: w.total_trades}}
      )
      |> Repo.all()
      |> Map.new()

    Logger.info("[Backfill] Loaded #{map_size(wallets_map)} wallets for wallet signal backfill")

    # Get trades that need wallet_age_days populated
    trades_query = from(t in Trade, where: is_nil(t.wallet_age_days), select: t)
    total_to_process = Repo.aggregate(trades_query, :count)

    Logger.info("[Backfill] #{total_to_process} trades need wallet signals populated")

    if dry_run do
      {:ok, %{updated: 0, errors: 0, skipped: 0, total: total_to_process, message: "Dry run - no changes made"}}
    else
      process_wallet_signal_batches(trades_query, wallets_map, batch_size)
    end
  end

  defp process_wallet_signal_batches(query, wallets_map, batch_size) do
    Repo.transaction(fn ->
      stats = %{updated: 0, errors: 0, skipped: 0}

      query
      |> Repo.stream(max_rows: batch_size)
      |> Stream.chunk_every(batch_size)
      |> Enum.reduce(stats, fn batch, acc ->
        batch_results = Enum.map(batch, fn trade ->
          update_trade_wallet_signals(trade, wallets_map)
        end)

        updated = Enum.count(batch_results, &match?(:ok, &1))
        errors = Enum.count(batch_results, &match?(:error, &1))
        skipped = Enum.count(batch_results, &match?(:skipped, &1))

        Logger.info("[Backfill] Processed batch: #{updated} updated, #{skipped} skipped, #{errors} errors")

        %{
          updated: acc.updated + updated,
          errors: acc.errors + errors,
          skipped: acc.skipped + skipped
        }
      end)
    end)
  end

  defp update_trade_wallet_signals(trade, wallets_map) do
    wallet_info = Map.get(wallets_map, trade.wallet_address, %{})
    first_seen = wallet_info[:first_seen_at]
    total_trades = wallet_info[:total_trades] || 0

    wallet_age_days = if first_seen && trade.trade_timestamp do
      case DateTime.diff(trade.trade_timestamp, first_seen, :day) do
        days when days < 0 -> 0
        days -> days
      end
    else
      nil
    end

    # Skip if we can't calculate wallet age (no first_seen_at data)
    if is_nil(wallet_age_days) do
      :skipped
    else
      case trade
           |> Trade.changeset(%{wallet_age_days: wallet_age_days, wallet_trade_count: total_trades})
           |> Repo.update() do
        {:ok, _} -> :ok
        {:error, _} -> :error
      end
    end
  end

  # ============================================
  # Private Helpers for Phase 2
  # ============================================

  defp determine_resolved_outcome(api_market) do
    case api_market["outcomePrices"] do
      str when is_binary(str) ->
        case Jason.decode(str) do
          {:ok, prices} -> parse_resolution_from_prices(prices, api_market)
          _ -> nil
        end
      prices when is_list(prices) ->
        parse_resolution_from_prices(prices, api_market)
      _ ->
        nil
    end
  end

  defp parse_resolution_from_prices(prices, api_market) when is_list(prices) do
    outcomes = case api_market["outcomes"] do
      str when is_binary(str) ->
        case Jason.decode(str) do
          {:ok, list} -> list
          _ -> ["Yes", "No"]
        end
      list when is_list(list) -> list
      _ -> ["Yes", "No"]
    end

    # Find which outcome has price = 1 (or very close to 1)
    prices
    |> Enum.with_index()
    |> Enum.find(fn {price, _idx} ->
      parsed = parse_price_string(price)
      parsed != nil and Decimal.gt?(parsed, Decimal.new("0.99"))
    end)
    |> case do
      {_price, idx} -> Enum.at(outcomes, idx)
      nil -> nil
    end
  end

  defp parse_price_string(price) when is_binary(price) do
    case Decimal.parse(price) do
      {decimal, _} -> decimal
      :error -> nil
    end
  end
  defp parse_price_string(price) when is_number(price), do: Decimal.from_float(price * 1.0)
  defp parse_price_string(_), do: nil

  defp determine_trade_correctness(trade, market) do
    # A trade is "correct" if the trader bet on the winning outcome
    case trade.side do
      "BUY" ->
        # Bought an outcome - correct if that outcome won
        trade.outcome == market.resolved_outcome

      "SELL" ->
        # Sold an outcome - correct if that outcome LOST
        trade.outcome != market.resolved_outcome

      _ ->
        nil
    end
  end

  # ============================================
  # Phase 3: Baseline Calculation
  # ============================================

  @doc """
  Calculate pattern baselines for all metrics and categories.

  Computes statistical distributions (mean, stddev, percentiles) from
  historical trade data, segmented by market category.

  ## Parameters

  - `opts` - Keyword list of options:
    - `:categories` - List of categories to calculate (default: all)
    - `:include_all` - Also calculate "all" category (default: true)

  ## Returns

  - `{:ok, %{baselines_created: n, metrics: [...], categories: [...]}}` - Stats
  """
  def calculate_baselines(opts \\ []) do
    categories = Keyword.get(opts, :categories, PatternBaseline.market_categories() -- ["all"])
    include_all = Keyword.get(opts, :include_all, true)
    metrics = PatternBaseline.metric_names()

    Logger.info("Calculating baselines for #{length(categories)} categories and #{length(metrics)} metrics")

    # Calculate for each category
    category_results =
      categories
      |> Enum.flat_map(fn category ->
        Enum.map(metrics, fn metric ->
          calculate_metric_baseline(metric, category)
        end)
      end)

    # Calculate "all" category (across all trades)
    all_results = if include_all do
      Enum.map(metrics, fn metric ->
        calculate_metric_baseline(metric, "all")
      end)
    else
      []
    end

    all_results_combined = category_results ++ all_results
    created = Enum.count(all_results_combined, &match?({:ok, _}, &1))

    Logger.info("Baseline calculation complete: #{created} baselines created/updated")

    {:ok, %{
      baselines_created: created,
      metrics: metrics,
      categories: if(include_all, do: categories ++ ["all"], else: categories)
    }}
  end

  @doc """
  Calculate baseline for a specific metric and category.

  ## Parameters

  - `metric` - One of: "size", "usdc_size", "timing", "wallet_age", "wallet_activity", "price_extremity"
  - `category` - One of the market categories or "all"

  ## Returns

  - `{:ok, baseline}` - The created/updated baseline
  - `{:error, reason}` - If calculation fails
  """
  def calculate_metric_baseline(metric, category) do
    Logger.debug("Calculating baseline: #{metric} for #{category}")

    # Get trade values for this metric/category
    values = get_metric_values(metric, category)

    if length(values) < 10 do
      Logger.debug("Skipping #{metric}/#{category}: only #{length(values)} samples")
      {:error, :insufficient_data}
    else
      # Calculate statistics
      stats = calculate_distribution_stats(values)

      attrs = %{
        market_category: category,
        metric_name: metric,
        normal_mean: stats.mean,
        normal_stddev: stats.stddev,
        normal_median: stats.median,
        normal_p75: stats.p75,
        normal_p90: stats.p90,
        normal_p95: stats.p95,
        normal_p99: stats.p99,
        normal_sample_count: length(values),
        calculated_at: DateTime.utc_now()
      }

      # Upsert baseline
      case Repo.get_by(PatternBaseline, market_category: category, metric_name: metric) do
        nil ->
          %PatternBaseline{}
          |> PatternBaseline.changeset(attrs)
          |> Repo.insert()

        existing ->
          existing
          |> PatternBaseline.changeset(attrs)
          |> Repo.update()
      end
    end
  end

  @doc """
  Get a baseline by metric and category.

  ## Examples

      {:ok, baseline} = Polymarket.get_baseline("size", "politics")
  """
  def get_baseline(metric, category) do
    case Repo.get_by(PatternBaseline, market_category: category, metric_name: metric) do
      nil -> {:error, :not_found}
      baseline -> {:ok, baseline}
    end
  end

  @doc """
  List all baselines with optional filters.

  ## Options

  - `:category` - Filter by category
  - `:metric` - Filter by metric name

  ## Examples

      baselines = Polymarket.list_baselines(category: "politics")
  """
  def list_baselines(opts \\ []) do
    from(b in PatternBaseline, order_by: [b.market_category, b.metric_name])
    |> maybe_filter(:market_category, Keyword.get(opts, :category))
    |> maybe_filter(:metric_name, Keyword.get(opts, :metric))
    |> Repo.all()
  end

  @doc """
  Calculate z-score for a trade value against its baseline.

  ## Parameters

  - `metric` - The metric name
  - `category` - The market category
  - `value` - The trade's value for this metric

  ## Returns

  - `{:ok, zscore}` - The z-score (float)
  - `{:error, :no_baseline}` - If baseline doesn't exist
  """
  def calculate_zscore(metric, category, value) do
    case get_baseline(metric, category) do
      {:ok, baseline} ->
        zscore = PatternBaseline.calculate_zscore(baseline, value)
        {:ok, zscore}

      {:error, :not_found} ->
        # Fallback to "all" category
        case get_baseline(metric, "all") do
          {:ok, baseline} ->
            zscore = PatternBaseline.calculate_zscore(baseline, value)
            {:ok, zscore}
          _ ->
            {:error, :no_baseline}
        end
    end
  end

  @doc """
  Score a single trade against baselines.

  Calculates z-scores for all metrics and computes anomaly score.

  ## Parameters

  - `trade` - Trade struct with preloaded market

  ## Returns

  - `{:ok, trade_score}` - Created/updated TradeScore
  """
  def score_trade(%Trade{} = trade) do
    # Get market category
    market = if trade.market_id do
      Repo.get(Market, trade.market_id)
    end

    category = if market, do: Atom.to_string(market.category), else: "all"

    # Calculate z-scores for each metric
    size_z = safe_zscore("size", category, trade.size)
    usdc_z = safe_zscore("usdc_size", category, trade.usdc_size)
    timing_z = safe_zscore("timing", category, trade.hours_before_resolution)
    wallet_age_z = safe_zscore("wallet_age", category, trade.wallet_age_days)
    activity_z = safe_zscore("wallet_activity", category, trade.wallet_trade_count)
    price_z = safe_zscore("price_extremity", category, trade.price_extremity)

    # Calculate position concentration z-score
    concentration_z = case calculate_position_concentration(trade.wallet_address, trade.condition_id) do
      {:ok, concentration} ->
        case position_concentration_zscore(concentration) do
          {:ok, z} -> z
          _ -> nil
        end
      _ -> nil
    end

    # Use the most relevant z-scores (skip nil)
    zscores = [size_z, usdc_z, timing_z, wallet_age_z, activity_z, price_z, concentration_z] |> Enum.reject(&is_nil/1)

    anomaly_score = TradeScore.calculate_anomaly_score(zscores)
    insider_prob = TradeScore.calculate_insider_probability(anomaly_score, nil, trade.was_correct)

    # Build breakdown
    breakdown = TradeScore.build_anomaly_breakdown(%{
      size: size_z || 0,
      timing: timing_z || 0,
      wallet_age: wallet_age_z || 0,
      wallet_activity: activity_z || 0,
      price_extremity: price_z || 0,
      position_concentration: concentration_z || 0
    })

    attrs = %{
      trade_id: trade.id,
      transaction_hash: trade.transaction_hash,
      size_zscore: decimal_or_nil(size_z),
      timing_zscore: decimal_or_nil(timing_z),
      wallet_age_zscore: decimal_or_nil(wallet_age_z),
      wallet_activity_zscore: decimal_or_nil(activity_z),
      price_extremity_zscore: decimal_or_nil(price_z),
      position_concentration_zscore: decimal_or_nil(concentration_z),
      anomaly_score: anomaly_score,
      insider_probability: insider_prob,
      matched_patterns: breakdown,
      scored_at: DateTime.utc_now()
    }

    case Repo.get_by(TradeScore, trade_id: trade.id) do
      nil ->
        %TradeScore{}
        |> TradeScore.changeset(attrs)
        |> Repo.insert()

      existing ->
        existing
        |> TradeScore.changeset(attrs)
        |> Repo.update()
    end
  end

  @doc """
  Score all trades for resolved markets.

  ## Parameters

  - `opts` - Keyword list of options:
    - `:limit` - Max trades to score (default: all)
    - `:only_unscored` - Only score trades without existing scores (default: true)

  ## Returns

  - `{:ok, %{scored: n, errors: n}}` - Stats
  """
  def score_all_trades(opts \\ []) do
    limit = Keyword.get(opts, :limit)
    only_unscored = Keyword.get(opts, :only_unscored, true)

    Logger.info("Scoring trades (limit: #{inspect(limit)}, only_unscored: #{only_unscored})")

    # Build query for trades to score
    base_query =
      from(t in Trade,
        join: m in Market, on: t.market_id == m.id,
        where: not is_nil(m.resolved_outcome),
        preload: [market: m]
      )

    query = if only_unscored do
      from(t in base_query,
        left_join: s in TradeScore, on: s.trade_id == t.id,
        where: is_nil(s.id)
      )
    else
      base_query
    end

    query = if limit, do: from(q in query, limit: ^limit), else: query

    trades = Repo.all(query)
    Logger.info("Found #{length(trades)} trades to score")

    results = Enum.map(trades, fn trade ->
      score_trade(trade)
    end)

    stats = %{
      scored: Enum.count(results, &match?({:ok, _}, &1)),
      errors: Enum.count(results, &match?({:error, _}, &1))
    }

    Logger.info("Scoring complete: #{inspect(stats)}")
    {:ok, stats}
  end

  @doc """
  Get baseline statistics summary.

  Returns overview of all calculated baselines.
  """
  def baseline_stats do
    baselines = Repo.all(PatternBaseline)

    by_category =
      baselines
      |> Enum.group_by(& &1.market_category)
      |> Enum.map(fn {cat, bs} -> {cat, length(bs)} end)
      |> Map.new()

    by_metric =
      baselines
      |> Enum.group_by(& &1.metric_name)
      |> Enum.map(fn {metric, bs} -> {metric, length(bs)} end)
      |> Map.new()

    total_samples =
      baselines
      |> Enum.map(& &1.normal_sample_count || 0)
      |> Enum.sum()

    %{
      total_baselines: length(baselines),
      by_category: by_category,
      by_metric: by_metric,
      total_samples: total_samples
    }
  end

  # ============================================
  # Private Helpers for Phase 3
  # ============================================

  defp get_metric_values(metric, category) do
    base_query =
      if category == "all" do
        from(t in Trade,
          join: m in Market, on: t.market_id == m.id,
          where: not is_nil(m.resolved_outcome)
        )
      else
        category_atom = String.to_existing_atom(category)
        from(t in Trade,
          join: m in Market, on: t.market_id == m.id,
          where: not is_nil(m.resolved_outcome) and m.category == ^category_atom
        )
      end

    # Build metric-specific query
    query = case metric do
      "size" ->
        from(t in base_query, select: t.size, where: not is_nil(t.size))
      "usdc_size" ->
        from(t in base_query, select: t.usdc_size, where: not is_nil(t.usdc_size))
      "timing" ->
        from(t in base_query, select: t.hours_before_resolution, where: not is_nil(t.hours_before_resolution))
      "wallet_age" ->
        from(t in base_query, select: t.wallet_age_days, where: not is_nil(t.wallet_age_days))
      "wallet_activity" ->
        from(t in base_query, select: t.wallet_trade_count, where: not is_nil(t.wallet_trade_count))
      "price_extremity" ->
        from(t in base_query, select: t.price_extremity, where: not is_nil(t.price_extremity))
      _ ->
        from(t in base_query, select: t.size, where: not is_nil(t.size))
    end

    query
    |> Repo.all()
    |> Enum.map(&ensure_float/1)
    |> Enum.reject(&is_nil/1)
  end

  defp calculate_distribution_stats(values) when length(values) > 0 do
    sorted = Enum.sort(values)
    n = length(sorted)

    mean = Enum.sum(sorted) / n

    variance =
      sorted
      |> Enum.map(fn v -> (v - mean) * (v - mean) end)
      |> Enum.sum()
      |> Kernel./(n)

    stddev = :math.sqrt(variance)

    %{
      mean: Decimal.from_float(Float.round(mean, 6)),
      stddev: Decimal.from_float(Float.round(stddev, 6)),
      median: Decimal.from_float(Float.round(percentile(sorted, 50), 6)),
      p75: Decimal.from_float(Float.round(percentile(sorted, 75), 6)),
      p90: Decimal.from_float(Float.round(percentile(sorted, 90), 6)),
      p95: Decimal.from_float(Float.round(percentile(sorted, 95), 6)),
      p99: Decimal.from_float(Float.round(percentile(sorted, 99), 6))
    }
  end

  defp calculate_distribution_stats([]), do: %{mean: nil, stddev: nil, median: nil, p75: nil, p90: nil, p95: nil, p99: nil}

  defp percentile(sorted_list, p) when p >= 0 and p <= 100 do
    n = length(sorted_list)
    rank = (p / 100) * (n - 1)
    lower_idx = floor(rank)
    upper_idx = ceil(rank)
    weight = rank - lower_idx

    lower_val = Enum.at(sorted_list, lower_idx)
    upper_val = Enum.at(sorted_list, upper_idx)

    lower_val + weight * (upper_val - lower_val)
  end

  defp safe_zscore(metric, category, value) do
    case calculate_zscore(metric, category, value) do
      {:ok, z} when is_number(z) -> z
      _ -> nil
    end
  end

  defp decimal_or_nil(nil), do: nil
  defp decimal_or_nil(n) when is_float(n), do: Decimal.from_float(Float.round(n, 3))
  defp decimal_or_nil(n) when is_integer(n), do: Decimal.new(n)

  defp ensure_float(%Decimal{} = d), do: Decimal.to_float(d)
  defp ensure_float(n) when is_float(n), do: n
  defp ensure_float(n) when is_integer(n), do: n * 1.0
  defp ensure_float(nil), do: nil

  @doc """
  Calculate position concentration for a wallet on a specific market.

  Measures how directional a wallet's trades are:
  - 1.0 = All trades on one side (100% YES or 100% NO)
  - 0.0 = Equal trades on both sides

  High concentration combined with correct outcome strongly indicates insider.

  ## Returns

  - `{:ok, concentration}` where concentration is 0.0 to 1.0
  - `{:error, :insufficient_data}` if wallet has no trades on this market
  """
  def calculate_position_concentration(wallet_address, condition_id) do
    # Get all trades for this wallet on this market
    trades = from(t in Trade,
      where: t.wallet_address == ^wallet_address and t.condition_id == ^condition_id,
      select: %{
        outcome: t.outcome,
        side: t.side,
        size: t.size
      }
    ) |> Repo.all()

    if Enum.empty?(trades) do
      {:error, :insufficient_data}
    else
      # Calculate net position for each outcome
      # BUY adds to position, SELL subtracts
      position_by_outcome = Enum.reduce(trades, %{}, fn trade, acc ->
        outcome = trade.outcome || "unknown"
        size = ensure_float(trade.size) || 0.0
        direction = if trade.side == "BUY", do: 1.0, else: -1.0

        Map.update(acc, outcome, size * direction, &(&1 + size * direction))
      end)

      # Calculate total absolute position
      total_abs_position = position_by_outcome
        |> Map.values()
        |> Enum.map(&abs/1)
        |> Enum.sum()

      if total_abs_position == 0 do
        {:ok, 0.0}
      else
        # Find the dominant position (max absolute value)
        dominant_position = position_by_outcome
          |> Map.values()
          |> Enum.map(&abs/1)
          |> Enum.max()

        # Concentration = dominant / total
        # If all on one side, concentration = 1.0
        # If split equally, concentration approaches 0.5
        # Normalize to 0-1 scale where 0.5 base -> 0, 1.0 -> 1.0
        raw_concentration = dominant_position / total_abs_position

        # Scale: 0.5 (balanced) -> 0.0, 1.0 (all one side) -> 1.0
        concentration = max(0.0, (raw_concentration - 0.5) * 2.0)

        {:ok, Float.round(concentration, 4)}
      end
    end
  end

  @doc """
  Calculate z-score for position concentration.

  Since position concentration doesn't have natural baselines (it's a ratio 0-1),
  we convert it to a z-score based on typical distribution:
  - Mean concentration: ~0.6 (slight directional bias is normal)
  - StdDev: ~0.2

  High concentration (>0.9) → z-score > 1.5
  Very high (>0.95) → z-score > 1.75

  Note: This is a simpler approach than baseline lookup since
  concentration is inherently normalized.
  """
  def position_concentration_zscore(concentration) when is_float(concentration) do
    # Empirical estimates for normal trading
    mean = 0.6
    stddev = 0.2

    z = (concentration - mean) / stddev
    {:ok, Float.round(z, 3)}
  end
  def position_concentration_zscore(_), do: {:ok, 0.0}

  # ============================================
  # Phase 4: Confirmed Insiders
  # ============================================

  @doc """
  Add a confirmed insider case.

  ## Parameters

  - `attrs` - Map with:
    - `:wallet_address` - Required wallet address
    - `:condition_id` - Market condition ID
    - `:confidence_level` - "suspected", "likely", or "confirmed"
    - `:confirmation_source` - Source type
    - `:evidence_summary` - Description of evidence
    - `:evidence_links` - Map of supporting links
    - `:trade_size` - Optional trade size
    - `:estimated_profit` - Optional profit

  ## Returns

  - `{:ok, insider}` - Created insider record
  - `{:error, changeset}` - Validation error
  """
  def add_confirmed_insider(attrs) do
    attrs = Map.put_new(attrs, :confirmed_at, DateTime.utc_now())

    # Try to find matching trade
    attrs = case find_insider_trade(attrs) do
      {:ok, trade} ->
        attrs
        |> Map.put(:trade_id, trade.id)
        |> Map.put(:transaction_hash, trade.transaction_hash)
        |> Map.put_new(:trade_size, trade.size)
        |> Map.put_new(:estimated_profit, trade.profit_loss)
      _ ->
        attrs
    end

    %ConfirmedInsider{}
    |> ConfirmedInsider.changeset(attrs)
    |> Repo.insert()
  end

  defp find_insider_trade(%{wallet_address: wallet, condition_id: condition_id}) when not is_nil(wallet) and not is_nil(condition_id) do
    trade = from(t in Trade,
      join: m in Market, on: t.market_id == m.id,
      where: t.wallet_address == ^wallet and m.condition_id == ^condition_id,
      order_by: [desc: t.size],
      limit: 1
    ) |> Repo.one()

    if trade, do: {:ok, trade}, else: {:error, :not_found}
  end
  defp find_insider_trade(_), do: {:error, :missing_params}

  @doc """
  List confirmed insiders with optional filters.

  ## Parameters

  - `opts` - Keyword list of options:
    - `:confidence_level` - Filter by confidence level
    - `:confirmation_source` - Filter by source
    - `:used_for_training` - Filter by training status
    - `:limit` - Max results

  ## Returns

  - List of ConfirmedInsider records
  """
  def list_confirmed_insiders(opts \\ []) do
    confidence = Keyword.get(opts, :confidence_level)
    source = Keyword.get(opts, :confirmation_source)
    used_for_training = Keyword.get(opts, :used_for_training)
    limit = Keyword.get(opts, :limit)

    query = from(ci in ConfirmedInsider, order_by: [desc: ci.confirmed_at])

    query = if confidence, do: from(q in query, where: q.confidence_level == ^confidence), else: query
    query = if source, do: from(q in query, where: q.confirmation_source == ^source), else: query
    query = if not is_nil(used_for_training), do: from(q in query, where: q.used_for_training == ^used_for_training), else: query
    query = if limit, do: from(q in query, limit: ^limit), else: query

    Repo.all(query)
  end

  @doc """
  Get count of confirmed insiders by confidence level.
  """
  def confirmed_insider_stats do
    insiders = Repo.all(ConfirmedInsider)

    by_confidence =
      insiders
      |> Enum.group_by(& &1.confidence_level)
      |> Enum.map(fn {level, items} -> {level, length(items)} end)
      |> Map.new()

    by_source =
      insiders
      |> Enum.group_by(& &1.confirmation_source)
      |> Enum.map(fn {src, items} -> {src, length(items)} end)
      |> Map.new()

    total_profit =
      insiders
      |> Enum.map(& Decimal.to_float(&1.estimated_profit || Decimal.new(0)))
      |> Enum.sum()

    %{
      total: length(insiders),
      by_confidence: by_confidence,
      by_source: by_source,
      total_estimated_profit: total_profit
    }
  end

  @doc """
  Seed known insider cases from documented sources.

  Seeds documented insider trading cases from news reports and investigations.
  """
  def seed_known_insiders do
    Logger.info("Seeding known insider cases...")

    # Venezuela/Maduro case - documented by Futurism, CryptoNinjas
    # Three wallets made $630K betting on Trump's Venezuela action
    cases = [
      %{
        wallet_address: "0xbacd00c9080a82ded56f504ee8810af732b0ab35",
        condition_id: get_condition_id_for_question("Trump invokes War Powers against Venezuela by January 9"),
        confidence_level: "likely",
        confirmation_source: "news_report",
        evidence_summary: "Large whale trades on Venezuela War Powers market. Multiple high-value BUY Yes trades before resolution. Part of documented $630K insider case.",
        evidence_links: %{
          futurism: "https://futurism.com/future-society/evidence-trump-venezuela-polymarket",
          cryptoninjas: "https://www.cryptoninjas.net/news/630k-insider-bet-exposed-as-polymarket-wallets-predicted-maduros-fall-hours-before-arrest/"
        }
      },
      %{
        wallet_address: "0x04c280993dfcca68254cb51753125ddf1c13db08",
        condition_id: get_condition_id_for_question("Trump invokes War Powers against Venezuela by January 9"),
        confidence_level: "likely",
        confirmation_source: "news_report",
        evidence_summary: "SELL No trades (equivalent to betting Yes) on Venezuela market. Large positions, correct prediction. Associated with documented insider case.",
        evidence_links: %{
          futurism: "https://futurism.com/future-society/evidence-trump-venezuela-polymarket"
        }
      },
      %{
        wallet_address: "0x631c2b93ff03c21d29b2b73af4ff965e88ea450f",
        condition_id: get_condition_id_for_question("Trump invokes War Powers against Venezuela by January 9"),
        confidence_level: "suspected",
        confirmation_source: "pattern_match",
        evidence_summary: "Large BUY Yes trade at 0.99 price, correct prediction. High anomaly score, similar pattern to documented insider trades.",
        evidence_links: %{}
      }
    ]

    results = Enum.map(cases, fn case_attrs ->
      case add_confirmed_insider(case_attrs) do
        {:ok, insider} ->
          Logger.info("Added insider: #{insider.wallet_address} (#{insider.confidence_level})")
          {:ok, insider}
        {:error, changeset} ->
          Logger.warning("Failed to add insider: #{inspect(changeset.errors)}")
          {:error, changeset}
      end
    end)

    stats = %{
      added: Enum.count(results, &match?({:ok, _}, &1)),
      failed: Enum.count(results, &match?({:error, _}, &1))
    }

    Logger.info("Seeding complete: #{inspect(stats)}")
    {:ok, stats}
  end

  defp get_condition_id_for_question(question_fragment) do
    market = from(m in Market, where: ilike(m.question, ^"%#{question_fragment}%"), limit: 1) |> Repo.one()
    if market, do: market.condition_id, else: nil
  end

  @doc """
  Calculate insider-specific baselines.

  Computes statistical distributions for trades from confirmed insiders,
  enabling comparison with normal trading patterns.

  ## Returns

  - `{:ok, %{updated: n}}` - Stats on updated baselines
  """
  def calculate_insider_baselines do
    Logger.info("Calculating insider baselines...")

    # Get all confirmed insider trade IDs
    insider_trade_ids = from(ci in ConfirmedInsider,
      where: not is_nil(ci.trade_id),
      select: ci.trade_id
    ) |> Repo.all()

    if length(insider_trade_ids) == 0 do
      Logger.warning("No confirmed insider trades found for baseline calculation")
      {:ok, %{updated: 0, message: "No insider trades with linked trade_id"}}
    else
      Logger.info("Found #{length(insider_trade_ids)} insider trades for baseline calculation")

      # Get insider trades
      insider_trades = from(t in Trade,
        where: t.id in ^insider_trade_ids,
        preload: [:market]
      ) |> Repo.all()

      # Calculate stats for each metric
      metrics = PatternBaseline.metric_names()

      results = Enum.map(metrics, fn metric ->
        values = get_insider_metric_values(insider_trades, metric)

        if length(values) > 0 do
          stats = calculate_distribution_stats(values)

          # Update the "all" category baseline with insider stats
          case Repo.get_by(PatternBaseline, market_category: "all", metric_name: metric) do
            nil ->
              Logger.warning("No baseline found for all/#{metric}")
              :skip
            baseline ->
              baseline
              |> PatternBaseline.changeset(%{
                insider_mean: stats.mean,
                insider_stddev: stats.stddev,
                insider_sample_count: length(values),
                separation_score: calculate_separation_score(baseline, stats)
              })
              |> Repo.update()
          end
        else
          :skip
        end
      end)

      updated = Enum.count(results, &match?({:ok, _}, &1))
      {:ok, %{updated: updated}}
    end
  end

  defp get_insider_metric_values(trades, metric) do
    trades
    |> Enum.map(fn trade ->
      case metric do
        "size" -> trade.size
        "usdc_size" -> trade.usdc_size
        "timing" -> trade.hours_before_resolution
        "wallet_age" -> trade.wallet_age_days
        "wallet_activity" -> trade.wallet_trade_count
        "price_extremity" -> trade.price_extremity
      end
    end)
    |> Enum.reject(&is_nil/1)
    |> Enum.map(&ensure_float/1)
    |> Enum.reject(&is_nil/1)
  end

  defp calculate_separation_score(baseline, insider_stats) do
    # Cohen's d: (insider_mean - normal_mean) / pooled_stddev
    normal_mean = ensure_float(baseline.normal_mean)
    normal_stddev = ensure_float(baseline.normal_stddev)
    insider_mean = ensure_float(insider_stats.mean)
    insider_stddev = ensure_float(insider_stats.stddev)

    if normal_stddev && normal_stddev > 0 && insider_stddev && insider_stddev > 0 do
      pooled = :math.sqrt((normal_stddev * normal_stddev + insider_stddev * insider_stddev) / 2)
      if pooled > 0 do
        separation = abs(insider_mean - normal_mean) / pooled
        Decimal.from_float(Float.round(min(separation, 9.9999), 4))
      else
        nil
      end
    else
      nil
    end
  end

  # ============================================
  # Phase 5: Insider Patterns
  # ============================================

  @doc """
  Create a new insider pattern.

  ## Parameters

  - `attrs` - Map with:
    - `:pattern_name` - Unique name (required)
    - `:description` - Human-readable description
    - `:conditions` - Pattern conditions map
    - `:alert_threshold` - Score threshold for alerts

  ## Returns

  - `{:ok, pattern}` - Created pattern
  - `{:error, changeset}` - Validation error
  """
  def create_insider_pattern(attrs) do
    %InsiderPattern{}
    |> InsiderPattern.changeset(attrs)
    |> Repo.insert()
  end

  @doc """
  Get an insider pattern by name.
  """
  def get_insider_pattern(name) do
    Repo.get_by(InsiderPattern, pattern_name: name)
  end

  @doc """
  List all insider patterns.

  ## Parameters

  - `opts` - Keyword list of options:
    - `:active_only` - Only return active patterns (default: true)
  """
  def list_insider_patterns(opts \\ []) do
    active_only = Keyword.get(opts, :active_only, true)

    query = from(p in InsiderPattern, order_by: [desc: p.f1_score, asc: p.pattern_name])
    query = if active_only, do: from(q in query, where: q.is_active == true), else: query

    Repo.all(query)
  end

  @doc """
  Seed predefined insider patterns based on Phase 4 analysis.

  Creates patterns based on statistical separation scores:
  - Size is strongest indicator (5.69 separation)
  - Price extremity moderate (1.25)
  - Timing moderate (1.12)
  """
  def seed_insider_patterns do
    Logger.info("Seeding insider patterns...")

    patterns = [
      # Pattern 1: Whale Trade (strongest signal)
      %{
        pattern_name: "whale_trade",
        description: "Large trade size (>2 stddev above mean). Based on 5.69 separation score - insiders trade 23x larger than normal.",
        conditions: %{
          "rules" => [
            %{"metric" => "size_zscore", "operator" => ">=", "value" => 2.0}
          ],
          "logic" => "AND"
        },
        alert_threshold: Decimal.new("0.5")
      },

      # Pattern 2: Whale + Correct
      %{
        pattern_name: "whale_correct",
        description: "Large trade that predicted correctly. High confidence signal.",
        conditions: %{
          "rules" => [
            %{"metric" => "size_zscore", "operator" => ">=", "value" => 2.0},
            %{"metric" => "was_correct", "operator" => "==", "value" => true}
          ],
          "logic" => "AND"
        },
        alert_threshold: Decimal.new("0.6")
      },

      # Pattern 3: Extreme Whale + Correct
      %{
        pattern_name: "extreme_whale_correct",
        description: "Very large trade (>3 stddev) that predicted correctly. Highest confidence.",
        conditions: %{
          "rules" => [
            %{"metric" => "size_zscore", "operator" => ">=", "value" => 3.0},
            %{"metric" => "was_correct", "operator" => "==", "value" => true}
          ],
          "logic" => "AND"
        },
        alert_threshold: Decimal.new("0.7")
      },

      # Pattern 4: High Anomaly Score
      %{
        pattern_name: "high_anomaly",
        description: "Combined anomaly score above 0.5 threshold.",
        conditions: %{
          "rules" => [
            %{"metric" => "anomaly_score", "operator" => ">=", "value" => 0.5}
          ],
          "logic" => "AND"
        },
        alert_threshold: Decimal.new("0.5")
      },

      # Pattern 5: High Anomaly + Correct
      %{
        pattern_name: "high_anomaly_correct",
        description: "High anomaly score trade that was correct.",
        conditions: %{
          "rules" => [
            %{"metric" => "anomaly_score", "operator" => ">=", "value" => 0.5},
            %{"metric" => "was_correct", "operator" => "==", "value" => true}
          ],
          "logic" => "AND"
        },
        alert_threshold: Decimal.new("0.6")
      },

      # Pattern 6: Extreme Price + Correct
      %{
        pattern_name: "extreme_price_correct",
        description: "Trade at extreme odds (near 0 or 1) that was correct.",
        conditions: %{
          "rules" => [
            %{"metric" => "price_extremity_zscore", "operator" => ">=", "value" => 1.5},
            %{"metric" => "was_correct", "operator" => "==", "value" => true}
          ],
          "logic" => "AND"
        },
        alert_threshold: Decimal.new("0.5")
      },

      # Pattern 7: Multi-Signal (comprehensive)
      %{
        pattern_name: "multi_signal",
        description: "Multiple anomaly indicators present. At least 2 of: large size, extreme price, high anomaly.",
        conditions: %{
          "rules" => [
            %{"metric" => "size_zscore", "operator" => ">=", "value" => 2.0},
            %{"metric" => "price_extremity_zscore", "operator" => ">=", "value" => 1.5},
            %{"metric" => "anomaly_score", "operator" => ">=", "value" => 0.5}
          ],
          "logic" => "OR",
          "min_matches" => 2
        },
        alert_threshold: Decimal.new("0.6")
      },

      # Pattern 8: Perfect Storm (all signals)
      %{
        pattern_name: "perfect_storm",
        description: "All major signals present: large size, correct prediction, high anomaly score.",
        conditions: %{
          "rules" => [
            %{"metric" => "size_zscore", "operator" => ">=", "value" => 2.0},
            %{"metric" => "was_correct", "operator" => "==", "value" => true},
            %{"metric" => "anomaly_score", "operator" => ">=", "value" => 0.5}
          ],
          "logic" => "AND"
        },
        alert_threshold: Decimal.new("0.7")
      }
    ]

    results = Enum.map(patterns, fn pattern_attrs ->
      case create_insider_pattern(pattern_attrs) do
        {:ok, pattern} ->
          Logger.info("Created pattern: #{pattern.pattern_name}")
          {:ok, pattern}
        {:error, changeset} ->
          if Keyword.has_key?(changeset.errors, :pattern_name) do
            Logger.debug("Pattern already exists: #{pattern_attrs.pattern_name}")
            {:skip, pattern_attrs.pattern_name}
          else
            Logger.warning("Failed to create pattern: #{inspect(changeset.errors)}")
            {:error, changeset}
          end
      end
    end)

    stats = %{
      created: Enum.count(results, &match?({:ok, _}, &1)),
      skipped: Enum.count(results, &match?({:skip, _}, &1)),
      failed: Enum.count(results, &match?({:error, _}, &1))
    }

    Logger.info("Pattern seeding complete: #{inspect(stats)}")
    {:ok, stats}
  end

  @doc """
  Match a trade against all active patterns.

  ## Parameters

  - `trade_score` - TradeScore struct (or map with score data)
  - `trade` - Trade struct (or map with trade data)

  ## Returns

  - Map of pattern_name => match_score for matched patterns
  """
  def match_patterns(trade_score, trade \\ nil) do
    patterns = list_insider_patterns(active_only: true)

    # Build data map for pattern evaluation
    data = build_pattern_data(trade_score, trade)

    patterns
    |> Enum.map(fn pattern ->
      case InsiderPattern.evaluate(pattern, data) do
        {true, score} -> {pattern.pattern_name, score}
        {false, _} -> nil
      end
    end)
    |> Enum.reject(&is_nil/1)
    |> Map.new()
  end

  defp build_pattern_data(trade_score, trade) do
    score_data = case trade_score do
      %TradeScore{} = ts ->
        %{
          size_zscore: ts.size_zscore,
          timing_zscore: ts.timing_zscore,
          wallet_age_zscore: ts.wallet_age_zscore,
          wallet_activity_zscore: ts.wallet_activity_zscore,
          price_extremity_zscore: ts.price_extremity_zscore,
          anomaly_score: ts.anomaly_score,
          insider_probability: ts.insider_probability
        }
      map when is_map(map) -> map
    end

    trade_data = case trade do
      %Trade{} = t ->
        %{
          was_correct: t.was_correct,
          profit_loss: t.profit_loss,
          size: t.size,
          price: t.price
        }
      map when is_map(map) -> map
      nil -> %{}
    end

    Map.merge(score_data, trade_data)
  end

  @doc """
  Validate all patterns against confirmed insiders and all trades.

  Calculates precision, recall, F1, and lift for each pattern.

  ## Returns

  - `{:ok, %{validated: n, results: [...]}}` - Validation results
  """
  def validate_patterns do
    Logger.info("Validating insider patterns...")

    patterns = list_insider_patterns(active_only: false)

    # Get all confirmed insider trade IDs
    insider_trade_ids = from(ci in ConfirmedInsider,
      where: not is_nil(ci.trade_id),
      select: ci.trade_id
    ) |> Repo.all() |> MapSet.new()

    total_insiders = MapSet.size(insider_trade_ids)
    Logger.info("Found #{total_insiders} confirmed insider trades")

    if total_insiders == 0 do
      Logger.warning("No confirmed insiders to validate against")
      {:ok, %{validated: 0, message: "No confirmed insiders"}}
    else
      # Get all scored trades with their trade data
      scored_trades = from(ts in TradeScore,
        join: t in Trade, on: ts.trade_id == t.id,
        select: {ts, t}
      ) |> Repo.all()

      total_trades = length(scored_trades)
      Logger.info("Evaluating #{length(patterns)} patterns against #{total_trades} trades")

      results = Enum.map(patterns, fn pattern ->
        # Count matches
        matches = Enum.filter(scored_trades, fn {ts, t} ->
          case InsiderPattern.evaluate(pattern, build_pattern_data(ts, t)) do
            {true, _} -> true
            _ -> false
          end
        end)

        matched_trade_ids = Enum.map(matches, fn {ts, _t} -> ts.trade_id end) |> MapSet.new()

        # Calculate TP and FP
        true_positives = MapSet.intersection(matched_trade_ids, insider_trade_ids) |> MapSet.size()
        false_positives = MapSet.size(matched_trade_ids) - true_positives

        # Calculate metrics
        precision = InsiderPattern.calculate_precision(%{pattern | true_positives: true_positives, false_positives: false_positives})
        recall = InsiderPattern.calculate_recall(%{pattern | true_positives: true_positives}, total_insiders)
        f1 = InsiderPattern.calculate_f1(precision, recall)
        lift = InsiderPattern.calculate_lift(%{pattern | true_positives: true_positives, false_positives: false_positives}, total_insiders, total_trades)

        # Update pattern in database
        pattern
        |> InsiderPattern.changeset(%{
          true_positives: true_positives,
          false_positives: false_positives,
          precision: precision,
          recall: recall,
          f1_score: f1,
          lift: lift,
          validated_at: DateTime.utc_now()
        })
        |> Repo.update()

        %{
          pattern_name: pattern.pattern_name,
          true_positives: true_positives,
          false_positives: false_positives,
          total_matches: MapSet.size(matched_trade_ids),
          precision: precision && Decimal.to_float(precision),
          recall: recall && Decimal.to_float(recall),
          f1_score: f1 && Decimal.to_float(f1),
          lift: lift && Decimal.to_float(lift)
        }
      end)

      Logger.info("Pattern validation complete")
      {:ok, %{validated: length(results), total_insiders: total_insiders, total_trades: total_trades, results: results}}
    end
  end

  @doc """
  Get pattern performance summary.
  """
  def pattern_stats do
    patterns = list_insider_patterns(active_only: false)

    %{
      total_patterns: length(patterns),
      active_patterns: Enum.count(patterns, & &1.is_active),
      validated_patterns: Enum.count(patterns, & &1.validated_at != nil),
      best_f1: patterns |> Enum.map(& &1.f1_score) |> Enum.reject(&is_nil/1) |> Enum.max(fn -> nil end),
      best_precision: patterns |> Enum.map(& &1.precision) |> Enum.reject(&is_nil/1) |> Enum.max(fn -> nil end),
      best_lift: patterns |> Enum.map(& &1.lift) |> Enum.reject(&is_nil/1) |> Enum.max(fn -> nil end)
    }
  end

  # ============================================
  # Phase 7: Discovery Mode
  # ============================================

  @doc """
  Start a new discovery batch with parameters.

  ## Options

  - `:anomaly_threshold` - Minimum anomaly score (default: 0.5)
  - `:probability_threshold` - Minimum insider probability (default: 0.4)
  - `:filters` - Additional filters as map
  - `:notes` - Batch notes

  ## Example

      {:ok, batch} = Polymarket.start_discovery_batch(
        anomaly_threshold: 0.6,
        probability_threshold: 0.5
      )
  """
  def start_discovery_batch(opts \\ []) do
    batch_id = DiscoveryBatch.generate_batch_id()

    attrs = %{
      batch_id: batch_id,
      anomaly_threshold: Keyword.get(opts, :anomaly_threshold, Decimal.new("0.5")),
      probability_threshold: Keyword.get(opts, :probability_threshold, Decimal.new("0.4")),
      filters: Keyword.get(opts, :filters, %{}),
      notes: Keyword.get(opts, :notes),
      started_at: DateTime.utc_now()
    }

    %DiscoveryBatch{}
    |> DiscoveryBatch.changeset(attrs)
    |> Repo.insert()
  end

  @doc """
  Run discovery to find suspicious trades and generate investigation candidates.

  This is the main discovery function that:
  1. Queries all scored trades
  2. Filters by was_correct=true and event-based markets
  3. Ranks by insider_probability
  4. Extracts top N candidates
  5. Creates investigation candidate records

  ## Options

  - `:limit` - Maximum candidates to extract (default: 100)
  - `:min_profit` - Minimum estimated profit (default: 100)
  - `:exclude_confirmed` - Exclude already confirmed insiders (default: true)

  ## Example

      {:ok, batch} = Polymarket.start_discovery_batch()
      {:ok, result} = Polymarket.run_discovery(batch, limit: 50)
  """
  def run_discovery(%DiscoveryBatch{} = batch, opts \\ []) do
    limit = Keyword.get(opts, :limit, 100)
    min_profit = Keyword.get(opts, :min_profit, 100)
    exclude_confirmed = Keyword.get(opts, :exclude_confirmed, true)

    Logger.info("Starting discovery run: #{batch.batch_id}")

    anomaly_threshold = ensure_float(batch.anomaly_threshold)
    probability_threshold = ensure_float(batch.probability_threshold)

    # Get existing confirmed insider trade IDs to exclude
    confirmed_trade_ids =
      if exclude_confirmed do
        from(ci in ConfirmedInsider, where: not is_nil(ci.trade_id), select: ci.trade_id)
        |> Repo.all()
        |> MapSet.new()
      else
        MapSet.new()
      end

    # Get existing candidate trade IDs to avoid duplicates
    existing_candidate_ids =
      from(ic in InvestigationCandidate, where: not is_nil(ic.trade_id), select: ic.trade_id)
      |> Repo.all()
      |> MapSet.new()

    excluded_ids = MapSet.union(confirmed_trade_ids, existing_candidate_ids)

    Logger.info("Excluding #{MapSet.size(excluded_ids)} existing trades from discovery")

    # Query trade scores with trades and markets
    query =
      from ts in TradeScore,
        join: t in Trade, on: ts.trade_id == t.id,
        join: m in Market, on: t.market_id == m.id,
        where: not is_nil(ts.insider_probability),
        where: t.was_correct == true,
        where: m.is_event_based == true,
        where: ts.anomaly_score >= ^anomaly_threshold,
        where: ts.insider_probability >= ^probability_threshold,
        order_by: [desc: ts.insider_probability, desc: ts.anomaly_score],
        select: {ts, t, m}

    all_results = Repo.all(query)
    Logger.info("Found #{length(all_results)} trades matching thresholds")

    # Filter out excluded trades and apply profit filter
    filtered_results =
      all_results
      |> Enum.reject(fn {ts, _t, _m} -> MapSet.member?(excluded_ids, ts.trade_id) end)
      |> Enum.filter(fn {_ts, t, _m} ->
        profit = ensure_float(t.profit_loss)
        profit >= min_profit
      end)
      |> Enum.take(limit)

    Logger.info("After filters: #{length(filtered_results)} candidates")

    # Create investigation candidates
    candidates =
      filtered_results
      |> Enum.with_index(1)
      |> Enum.map(fn {{ts, t, m}, rank} ->
        create_investigation_candidate(ts, t, m, rank, batch.batch_id)
      end)
      |> Enum.filter(fn
        {:ok, _} -> true
        _ -> false
      end)
      |> Enum.map(fn {:ok, c} -> c end)

    # Calculate stats
    scores = Enum.map(candidates, fn c -> ensure_float(c.insider_probability) end)
    top_score = if scores != [], do: Enum.max(scores), else: nil
    median_score = if scores != [], do: calculate_median(scores), else: nil

    # Count markets analyzed
    markets_analyzed =
      from(m in Market, where: m.is_event_based == true and not is_nil(m.resolution_date))
      |> Repo.aggregate(:count, :id)

    trades_scored =
      from(ts in TradeScore)
      |> Repo.aggregate(:count, :id)

    # Update batch with results
    {:ok, updated_batch} =
      batch
      |> DiscoveryBatch.changeset(%{
        markets_analyzed: markets_analyzed,
        trades_scored: trades_scored,
        candidates_generated: length(candidates),
        top_candidate_score: top_score && Decimal.from_float(top_score),
        median_candidate_score: median_score && Decimal.from_float(median_score),
        completed_at: DateTime.utc_now()
      })
      |> Repo.update()

    Logger.info("Discovery complete: #{length(candidates)} candidates generated")

    {:ok, %{
      batch: updated_batch,
      candidates_created: length(candidates),
      top_score: top_score,
      median_score: median_score
    }}
  end

  defp create_investigation_candidate(trade_score, trade, market, rank, batch_id) do
    priority = InvestigationCandidate.calculate_priority(trade_score.insider_probability)
    anomaly_breakdown = InvestigationCandidate.build_anomaly_breakdown(trade_score)

    attrs = %{
      trade_id: trade.id,
      trade_score_id: trade_score.id,
      market_id: market.id,
      transaction_hash: trade.transaction_hash,
      wallet_address: trade.wallet_address,
      condition_id: market.condition_id,
      discovery_rank: rank,
      anomaly_score: trade_score.anomaly_score,
      insider_probability: trade_score.insider_probability,
      market_question: market.question,
      trade_size: trade.size,
      trade_outcome: trade.outcome,
      was_correct: trade.was_correct,
      estimated_profit: trade.profit_loss,
      hours_before_resolution: trade.hours_before_resolution,
      anomaly_breakdown: anomaly_breakdown,
      matched_patterns: trade_score.matched_patterns,
      status: "undiscovered",
      priority: priority,
      batch_id: batch_id,
      discovered_at: DateTime.utc_now()
    }

    %InvestigationCandidate{}
    |> InvestigationCandidate.changeset(attrs)
    |> Repo.insert()
  end

  defp calculate_median([]), do: nil
  defp calculate_median(list) do
    sorted = Enum.sort(list)
    len = length(sorted)
    mid = div(len, 2)

    if rem(len, 2) == 0 do
      (Enum.at(sorted, mid - 1) + Enum.at(sorted, mid)) / 2
    else
      Enum.at(sorted, mid)
    end
  end

  @doc """
  List investigation candidates with filtering.

  ## Options

  - `:status` - Filter by status
  - `:priority` - Filter by priority
  - `:batch_id` - Filter by batch
  - `:limit` - Maximum results (default: 50)
  - `:offset` - Offset for pagination

  ## Example

      candidates = Polymarket.list_investigation_candidates(
        status: "undiscovered",
        priority: "critical",
        limit: 20
      )
  """
  def list_investigation_candidates(opts \\ []) do
    query = from(ic in InvestigationCandidate, order_by: [asc: ic.discovery_rank])

    query =
      case Keyword.get(opts, :status) do
        nil -> query
        status -> from(ic in query, where: ic.status == ^status)
      end

    query =
      case Keyword.get(opts, :priority) do
        nil -> query
        priority -> from(ic in query, where: ic.priority == ^priority)
      end

    query =
      case Keyword.get(opts, :batch_id) do
        nil -> query
        batch_id -> from(ic in query, where: ic.batch_id == ^batch_id)
      end

    query =
      case Keyword.get(opts, :limit) do
        nil -> from(ic in query, limit: 50)
        limit -> from(ic in query, limit: ^limit)
      end

    query =
      case Keyword.get(opts, :offset) do
        nil -> query
        offset -> from(ic in query, offset: ^offset)
      end

    Repo.all(query)
  end

  @doc """
  Get a single investigation candidate by ID.
  """
  def get_investigation_candidate(id) do
    Repo.get(InvestigationCandidate, id)
  end

  @doc """
  Update candidate status and track investigation workflow.

  ## Example

      Polymarket.update_candidate_status(candidate, "investigating", "analyst@example.com")
  """
  def update_candidate_status(%InvestigationCandidate{} = candidate, status, assigned_to \\ nil) do
    attrs =
      case status do
        "investigating" ->
          %{
            status: status,
            assigned_to: assigned_to,
            investigation_started_at: DateTime.utc_now()
          }

        "resolved" ->
          %{
            status: status,
            resolved_at: DateTime.utc_now(),
            resolved_by: assigned_to
          }

        _ ->
          %{status: status}
      end

    candidate
    |> InvestigationCandidate.changeset(attrs)
    |> Repo.update()
  end

  @doc """
  Resolve a candidate with evidence and notes.

  ## Parameters

  - `candidate` - The investigation candidate
  - `resolution` - One of: "confirmed_insider", "likely_insider", "not_insider", "insufficient_evidence"
  - `opts` - Additional options:
    - `:evidence` - Evidence map
    - `:notes` - Investigation notes
    - `:resolved_by` - Who resolved it

  ## Example

      Polymarket.resolve_candidate(candidate, "confirmed_insider", %{
        evidence: %{article: "https://..."},
        notes: "Matched news report timing",
        resolved_by: "analyst@example.com"
      })
  """
  def resolve_candidate(%InvestigationCandidate{} = candidate, resolution, opts \\ []) do
    evidence = Keyword.get(opts, :evidence, %{})
    notes = Keyword.get(opts, :notes)
    resolved_by = Keyword.get(opts, :resolved_by)

    attrs = %{
      status: "resolved",
      resolution_evidence: Map.put(evidence, "resolution", resolution),
      investigation_notes: notes,
      resolved_at: DateTime.utc_now(),
      resolved_by: resolved_by
    }

    with {:ok, updated} <- candidate |> InvestigationCandidate.changeset(attrs) |> Repo.update() do
      # If confirmed insider, create confirmed insider record
      if resolution in ["confirmed_insider", "likely_insider"] do
        confidence = if resolution == "confirmed_insider", do: "confirmed", else: "likely"
        create_confirmed_from_candidate(updated, confidence)
      end

      {:ok, updated}
    end
  end

  defp create_confirmed_from_candidate(%InvestigationCandidate{} = candidate, confidence_level) do
    attrs = %{
      trade_id: candidate.trade_id,
      candidate_id: candidate.id,
      transaction_hash: candidate.transaction_hash,
      wallet_address: candidate.wallet_address,
      condition_id: candidate.condition_id,
      confidence_level: confidence_level,
      confirmation_source: "investigation",
      evidence_summary: candidate.investigation_notes,
      evidence_links: candidate.resolution_evidence,
      trade_size: candidate.trade_size,
      estimated_profit: candidate.estimated_profit,
      confirmed_at: DateTime.utc_now(),
      confirmed_by: candidate.resolved_by
    }

    %ConfirmedInsider{}
    |> ConfirmedInsider.changeset(attrs)
    |> Repo.insert()
  end

  @doc """
  List discovery batches with optional filtering.
  """
  def list_discovery_batches(opts \\ []) do
    query = from(db in DiscoveryBatch, order_by: [desc: db.started_at])

    query =
      case Keyword.get(opts, :limit) do
        nil -> query
        limit -> from(db in query, limit: ^limit)
      end

    Repo.all(query)
  end

  @doc """
  Get discovery batch by ID or batch_id string.
  """
  def get_discovery_batch(id) when is_integer(id) do
    Repo.get(DiscoveryBatch, id)
  end

  def get_discovery_batch(batch_id) when is_binary(batch_id) do
    Repo.get_by(DiscoveryBatch, batch_id: batch_id)
  end

  @doc """
  Get investigation candidates summary stats.
  """
  def investigation_stats do
    candidates = Repo.all(InvestigationCandidate)

    by_status =
      candidates
      |> Enum.group_by(& &1.status)
      |> Enum.map(fn {status, list} -> {status, length(list)} end)
      |> Map.new()

    by_priority =
      candidates
      |> Enum.group_by(& &1.priority)
      |> Enum.map(fn {priority, list} -> {priority, length(list)} end)
      |> Map.new()

    %{
      total: length(candidates),
      by_status: by_status,
      by_priority: by_priority,
      undiscovered: Map.get(by_status, "undiscovered", 0),
      investigating: Map.get(by_status, "investigating", 0),
      resolved: Map.get(by_status, "resolved", 0)
    }
  end

  @doc """
  Quick discovery: start batch, run discovery, return results.

  ## Options

  Same as `run_discovery/2` plus batch options.

  ## Example

      {:ok, result} = Polymarket.quick_discovery(limit: 50)
  """
  def quick_discovery(opts \\ []) do
    batch_opts = [
      anomaly_threshold: Keyword.get(opts, :anomaly_threshold, Decimal.new("0.5")),
      probability_threshold: Keyword.get(opts, :probability_threshold, Decimal.new("0.4")),
      notes: Keyword.get(opts, :notes, "Quick discovery run")
    ]

    with {:ok, batch} <- start_discovery_batch(batch_opts) do
      run_discovery(batch, opts)
    end
  end

  # ============================================
  # Phase 8: Investigation Workflow
  # ============================================

  @doc """
  Get a full investigation profile for a candidate.

  Returns comprehensive data for investigating a candidate including:
  - Candidate details
  - Wallet profile
  - Related trades
  - Similar patterns
  - Market context

  ## Example

      {:ok, profile} = Polymarket.get_investigation_profile(candidate_id)
  """
  def get_investigation_profile(candidate_id) do
    case get_investigation_candidate(candidate_id) do
      nil ->
        {:error, :not_found}

      candidate ->
        # Get wallet profile
        wallet_profile = build_wallet_profile(candidate.wallet_address)

        # Get related trades from same wallet
        related_trades = get_wallet_trades(candidate.wallet_address, limit: 20)

        # Get other trades in same market
        market_trades = get_market_suspicious_trades(candidate.market_id, candidate.trade_id)

        # Get similar candidates (same market or wallet)
        similar_candidates = get_similar_candidates(candidate)

        # Build profile
        {:ok, %{
          candidate: candidate,
          wallet_profile: wallet_profile,
          related_trades: related_trades,
          market_trades: market_trades,
          similar_candidates: similar_candidates,
          risk_assessment: build_risk_assessment(candidate, wallet_profile)
        }}
    end
  end

  @doc """
  Build a profile for a wallet address.

  Aggregates trading behavior metrics for investigation.
  """
  def build_wallet_profile(wallet_address) do
    wallet = Repo.get_by(Wallet, address: wallet_address)

    trades =
      from(t in Trade,
        where: t.wallet_address == ^wallet_address,
        order_by: [desc: t.trade_timestamp]
      )
      |> Repo.all()

    # Calculate win rate
    resolved_trades = Enum.filter(trades, & &1.was_correct != nil)
    wins = Enum.count(resolved_trades, & &1.was_correct == true)
    total_resolved = length(resolved_trades)
    win_rate = if total_resolved > 0, do: wins / total_resolved, else: nil

    # Calculate total profit/loss
    total_profit =
      trades
      |> Enum.map(& ensure_float(&1.profit_loss))
      |> Enum.sum()

    # Get unique markets
    unique_markets = trades |> Enum.map(& &1.market_id) |> Enum.uniq() |> length()

    # Calculate average trade size
    avg_size =
      if length(trades) > 0 do
        trades
        |> Enum.map(& ensure_float(&1.size))
        |> Enum.sum()
        |> Kernel./(length(trades))
      else
        0
      end

    # Get first and last trade dates
    first_trade = List.last(trades)
    last_trade = List.first(trades)

    %{
      address: wallet_address,
      wallet_id: wallet && wallet.id,
      pseudonym: wallet && wallet.pseudonym,
      total_trades: length(trades),
      resolved_trades: total_resolved,
      wins: wins,
      losses: total_resolved - wins,
      win_rate: win_rate && Float.round(win_rate, 4),
      total_profit: Float.round(total_profit, 2),
      unique_markets: unique_markets,
      avg_trade_size: Float.round(avg_size, 2),
      first_trade_at: first_trade && first_trade.trade_timestamp,
      last_trade_at: last_trade && last_trade.trade_timestamp,
      account_age_days: wallet && wallet.first_seen_at &&
        DateTime.diff(DateTime.utc_now(), wallet.first_seen_at, :day)
    }
  end

  @doc """
  Get trades for a wallet with optional filtering.

  ## Options

  - `:limit` - Maximum trades to return
  - `:market_id` - Filter by market
  - `:was_correct` - Filter by outcome
  """
  def get_wallet_trades(wallet_address, opts \\ []) do
    query =
      from(t in Trade,
        where: t.wallet_address == ^wallet_address,
        left_join: m in Market, on: t.market_id == m.id,
        left_join: ts in TradeScore, on: ts.trade_id == t.id,
        order_by: [desc: t.trade_timestamp],
        select: %{
          trade: t,
          market_question: m.question,
          anomaly_score: ts.anomaly_score,
          insider_probability: ts.insider_probability
        }
      )

    query =
      case Keyword.get(opts, :limit) do
        nil -> query
        limit -> from([t, m, ts] in query, limit: ^limit)
      end

    query =
      case Keyword.get(opts, :market_id) do
        nil -> query
        market_id -> from([t, m, ts] in query, where: t.market_id == ^market_id)
      end

    query =
      case Keyword.get(opts, :was_correct) do
        nil -> query
        was_correct -> from([t, m, ts] in query, where: t.was_correct == ^was_correct)
      end

    Repo.all(query)
  end

  @doc """
  Get other suspicious trades in the same market.

  Useful for identifying coordinated trading patterns.
  """
  def get_market_suspicious_trades(market_id, exclude_trade_id \\ nil) do
    query =
      from(ic in InvestigationCandidate,
        where: ic.market_id == ^market_id,
        order_by: [asc: ic.discovery_rank]
      )

    query =
      if exclude_trade_id do
        from(ic in query, where: ic.trade_id != ^exclude_trade_id)
      else
        query
      end

    Repo.all(query)
  end

  @doc """
  Get similar candidates based on wallet or market.
  """
  def get_similar_candidates(%InvestigationCandidate{} = candidate) do
    # Get candidates from same wallet
    same_wallet =
      from(ic in InvestigationCandidate,
        where: ic.wallet_address == ^candidate.wallet_address,
        where: ic.id != ^candidate.id,
        order_by: [asc: ic.discovery_rank],
        limit: 5
      )
      |> Repo.all()

    # Get candidates from same market
    same_market =
      from(ic in InvestigationCandidate,
        where: ic.market_id == ^candidate.market_id,
        where: ic.id != ^candidate.id,
        order_by: [asc: ic.discovery_rank],
        limit: 5
      )
      |> Repo.all()

    %{
      same_wallet: same_wallet,
      same_market: same_market
    }
  end

  @doc """
  Build a risk assessment for a candidate.
  """
  def build_risk_assessment(%InvestigationCandidate{} = candidate, wallet_profile) do
    risk_factors = []

    # Check anomaly factors
    risk_factors =
      if ensure_float(candidate.anomaly_score) >= 0.8 do
        ["Extreme anomaly score (#{candidate.anomaly_score})" | risk_factors]
      else
        risk_factors
      end

    # Check trade size
    size_z = get_in(candidate.anomaly_breakdown, ["size", "value"])
    risk_factors =
      if size_z && size_z >= 3.0 do
        ["Extreme trade size (#{Float.round(size_z, 2)} std devs)" | risk_factors]
      else
        risk_factors
      end

    # Check timing
    timing_z = get_in(candidate.anomaly_breakdown, ["timing", "value"])
    risk_factors =
      if timing_z && timing_z >= 2.0 do
        ["Suspicious timing (#{Float.round(timing_z, 2)} std devs before resolution)" | risk_factors]
      else
        risk_factors
      end

    # Check wallet history
    risk_factors =
      if wallet_profile.total_trades <= 5 do
        ["New/low activity wallet (#{wallet_profile.total_trades} trades)" | risk_factors]
      else
        risk_factors
      end

    # Check win rate
    risk_factors =
      if wallet_profile.win_rate && wallet_profile.win_rate >= 0.9 && wallet_profile.resolved_trades >= 5 do
        ["Unusually high win rate (#{Float.round(wallet_profile.win_rate * 100, 1)}%)" | risk_factors]
      else
        risk_factors
      end

    # Calculate overall risk level
    risk_level =
      cond do
        length(risk_factors) >= 4 -> "critical"
        length(risk_factors) >= 3 -> "high"
        length(risk_factors) >= 2 -> "medium"
        true -> "low"
      end

    %{
      risk_level: risk_level,
      risk_factors: risk_factors,
      factor_count: length(risk_factors)
    }
  end

  @doc """
  Add evidence to an investigation candidate.

  ## Evidence Types

  - `:link` - URL to external evidence
  - `:note` - Text note
  - `:screenshot` - Screenshot reference
  - `:blockchain` - Blockchain analysis data
  - `:news` - News article reference

  ## Example

      Polymarket.add_evidence(candidate, :link, %{
        url: "https://example.com/article",
        title: "News report about insider trading",
        added_by: "analyst@example.com"
      })
  """
  def add_evidence(%InvestigationCandidate{} = candidate, evidence_type, evidence_data) do
    timestamp = DateTime.utc_now() |> DateTime.to_iso8601()

    new_evidence = %{
      "type" => to_string(evidence_type),
      "data" => evidence_data,
      "added_at" => timestamp
    }

    existing_evidence = candidate.resolution_evidence || %{}
    evidence_list = Map.get(existing_evidence, "evidence", [])
    updated_evidence = Map.put(existing_evidence, "evidence", [new_evidence | evidence_list])

    candidate
    |> InvestigationCandidate.changeset(%{resolution_evidence: updated_evidence})
    |> Repo.update()
  end

  @doc """
  Add an investigation note to a candidate.
  """
  def add_investigation_note(%InvestigationCandidate{} = candidate, note, author \\ nil) do
    timestamp = DateTime.utc_now() |> DateTime.to_iso8601()

    existing_notes = candidate.investigation_notes || ""
    new_note = "[#{timestamp}#{if author, do: " - #{author}", else: ""}] #{note}"
    updated_notes = if existing_notes == "", do: new_note, else: "#{existing_notes}\n\n#{new_note}"

    candidate
    |> InvestigationCandidate.changeset(%{investigation_notes: updated_notes})
    |> Repo.update()
  end

  @doc """
  Start investigating a candidate.

  Marks status as investigating and records the investigator.
  """
  def start_investigation(%InvestigationCandidate{} = candidate, investigator) do
    candidate
    |> InvestigationCandidate.changeset(%{
      status: "investigating",
      assigned_to: investigator,
      investigation_started_at: DateTime.utc_now()
    })
    |> Repo.update()
  end

  @doc """
  Dismiss a candidate as not suspicious.
  """
  def dismiss_candidate(%InvestigationCandidate{} = candidate, reason, dismissed_by \\ nil) do
    candidate
    |> InvestigationCandidate.changeset(%{
      status: "dismissed",
      investigation_notes: "DISMISSED: #{reason}",
      resolved_at: DateTime.utc_now(),
      resolved_by: dismissed_by,
      resolution_evidence: %{"resolution" => "dismissed", "reason" => reason}
    })
    |> Repo.update()
  end

  @doc """
  Get investigation activity timeline.

  Returns recent investigation activity across all candidates.
  """
  def investigation_timeline(opts \\ []) do
    limit = Keyword.get(opts, :limit, 20)

    # Get recently updated candidates
    recent_candidates =
      from(ic in InvestigationCandidate,
        order_by: [desc: ic.updated_at],
        limit: ^limit
      )
      |> Repo.all()

    # Get recently confirmed insiders
    recent_confirmations =
      from(ci in ConfirmedInsider,
        order_by: [desc: ci.confirmed_at],
        limit: ^limit
      )
      |> Repo.all()

    %{
      recent_candidates: recent_candidates,
      recent_confirmations: recent_confirmations
    }
  end

  @doc """
  Search candidates by various criteria.

  ## Options

  - `:wallet_address` - Partial wallet address match
  - `:market_question` - Text search in market question
  - `:min_probability` - Minimum insider probability
  - `:min_profit` - Minimum estimated profit
  - `:priority` - Filter by priority
  - `:status` - Filter by status
  """
  def search_candidates(opts \\ []) do
    query = from(ic in InvestigationCandidate, order_by: [asc: ic.discovery_rank])

    query =
      case Keyword.get(opts, :wallet_address) do
        nil -> query
        addr -> from(ic in query, where: ilike(ic.wallet_address, ^"%#{addr}%"))
      end

    query =
      case Keyword.get(opts, :market_question) do
        nil -> query
        q -> from(ic in query, where: ilike(ic.market_question, ^"%#{q}%"))
      end

    query =
      case Keyword.get(opts, :min_probability) do
        nil -> query
        prob -> from(ic in query, where: ic.insider_probability >= ^prob)
      end

    query =
      case Keyword.get(opts, :min_profit) do
        nil -> query
        profit -> from(ic in query, where: ic.estimated_profit >= ^profit)
      end

    query =
      case Keyword.get(opts, :priority) do
        nil -> query
        priority -> from(ic in query, where: ic.priority == ^priority)
      end

    query =
      case Keyword.get(opts, :status) do
        nil -> query
        status -> from(ic in query, where: ic.status == ^status)
      end

    query =
      case Keyword.get(opts, :limit) do
        nil -> from(ic in query, limit: 50)
        limit -> from(ic in query, limit: ^limit)
      end

    Repo.all(query)
  end

  @doc """
  Get investigation dashboard summary.

  Returns overview stats for the investigation workflow.
  """
  def investigation_dashboard do
    # Candidate stats
    candidate_stats = investigation_stats()

    # Batch stats
    batches = list_discovery_batches(limit: 5)
    total_batches = Repo.aggregate(DiscoveryBatch, :count, :id)

    # Confirmed insider stats
    confirmed_count = Repo.aggregate(ConfirmedInsider, :count, :id)

    confirmed_by_level =
      from(ci in ConfirmedInsider,
        group_by: ci.confidence_level,
        select: {ci.confidence_level, count(ci.id)}
      )
      |> Repo.all()
      |> Map.new()

    # Pattern stats
    pattern_stats = pattern_stats()

    %{
      candidates: candidate_stats,
      batches: %{
        total: total_batches,
        recent: Enum.map(batches, &DiscoveryBatch.summary/1)
      },
      confirmed_insiders: %{
        total: confirmed_count,
        by_level: confirmed_by_level
      },
      patterns: pattern_stats,
      queue_summary: %{
        critical: candidate_stats.by_priority["critical"] || 0,
        high: candidate_stats.by_priority["high"] || 0,
        medium: candidate_stats.by_priority["medium"] || 0,
        low: candidate_stats.by_priority["low"] || 0
      }
    }
  end

  @doc """
  Bulk update candidate priorities based on new scoring.

  Recalculates priorities for all undiscovered candidates.
  """
  def refresh_candidate_priorities do
    candidates =
      from(ic in InvestigationCandidate, where: ic.status == "undiscovered")
      |> Repo.all()

    updated =
      Enum.map(candidates, fn candidate ->
        new_priority = InvestigationCandidate.calculate_priority(candidate.insider_probability)

        if new_priority != candidate.priority do
          {:ok, updated} =
            candidate
            |> InvestigationCandidate.changeset(%{priority: new_priority})
            |> Repo.update()
          updated
        else
          candidate
        end
      end)

    {:ok, %{
      total: length(candidates),
      updated: Enum.count(updated, fn c -> c.updated_at != c.inserted_at end)
    }}
  end

  # ============================================
  # Phase 9: Feedback Loop
  # ============================================

  @doc """
  Run a complete feedback loop iteration.

  The feedback loop improves detection by:
  1. Recalculating baselines with newly confirmed insiders
  2. Re-validating pattern precision/recall
  3. Re-scoring trades with improved baselines
  4. Running fresh discovery to find new candidates

  ## Options

  - `:rescore_trades` - Whether to re-score all trades (default: true, expensive)
  - `:discovery_limit` - Max candidates for new discovery (default: 100)
  - `:notes` - Notes for this iteration

  ## Returns

  - `{:ok, %{iteration: n, improvements: %{}, new_candidates: [...]}}` - Results

  ## Example

      # After confirming some insiders through investigation:
      {:ok, result} = Polymarket.run_feedback_loop(notes: "Iteration 2 after 5 confirmations")

      # View improvement metrics:
      result.improvements  # %{baseline_separation_delta: +0.15, pattern_f1_delta: +0.08}
  """
  def run_feedback_loop(opts \\ []) do
    Logger.info("Starting feedback loop iteration...")

    rescore = Keyword.get(opts, :rescore_trades, true)
    discovery_limit = Keyword.get(opts, :discovery_limit, 100)
    notes = Keyword.get(opts, :notes, "Feedback loop iteration")

    # Get baseline stats before iteration
    pre_stats = feedback_loop_stats()

    # Step 1: Mark newly confirmed insiders as ready for training
    {:ok, training_stats} = mark_insiders_for_training()
    Logger.info("Marked #{training_stats.newly_marked} insiders for training")

    # Step 2: Recalculate insider baselines with new confirmed insiders
    {:ok, insider_baseline_result} = calculate_insider_baselines()
    Logger.info("Updated insider baselines: #{insider_baseline_result.updated} metrics")

    # Step 3: Re-validate patterns against updated insider list
    {:ok, pattern_result} = validate_patterns()
    Logger.info("Validated #{pattern_result.validated} patterns")

    # Step 4: Optionally re-score trades with updated baselines
    rescore_result = if rescore do
      {:ok, result} = rescore_all_trades()
      Logger.info("Re-scored #{result.scored} trades")
      result
    else
      %{scored: 0, skipped: true}
    end

    # Step 5: Run new discovery with updated scores
    {:ok, discovery_result} = quick_discovery(
      limit: discovery_limit,
      notes: "#{notes} - auto-discovery"
    )
    Logger.info("Discovery found #{discovery_result.candidates_created} new candidates")

    # Get post-iteration stats
    post_stats = feedback_loop_stats()

    # Calculate improvements
    improvements = calculate_improvements(pre_stats, post_stats)

    iteration_number = get_iteration_count() + 1

    result = %{
      iteration: iteration_number,
      timestamp: DateTime.utc_now(),
      notes: notes,
      steps: %{
        training_marked: training_stats.newly_marked,
        baselines_updated: insider_baseline_result.updated,
        patterns_validated: pattern_result.validated,
        trades_rescored: rescore_result.scored,
        candidates_found: discovery_result.candidates_created
      },
      pre_stats: pre_stats,
      post_stats: post_stats,
      improvements: improvements,
      discovery_batch: discovery_result.batch.batch_id
    }

    Logger.info("Feedback loop iteration #{iteration_number} complete")
    Logger.info("Improvements: #{inspect(improvements)}")

    {:ok, result}
  end

  @doc """
  Get current feedback loop statistics.

  Returns stats useful for measuring iteration improvements.
  """
  def feedback_loop_stats do
    # Confirmed insider counts
    insiders = list_confirmed_insiders()
    total_insiders = length(insiders)
    trained_insiders = Enum.count(insiders, & &1.used_for_training)

    # Baseline separation scores
    baselines = list_baselines(category: "all")
    separation_scores = baselines
      |> Enum.map(& &1.separation_score)
      |> Enum.reject(&is_nil/1)
      |> Enum.map(&Decimal.to_float/1)

    avg_separation = if length(separation_scores) > 0 do
      Enum.sum(separation_scores) / length(separation_scores)
    else
      0
    end

    # Pattern metrics
    patterns = list_insider_patterns(active_only: true)
    pattern_f1_scores = patterns
      |> Enum.map(& &1.f1_score)
      |> Enum.reject(&is_nil/1)
      |> Enum.map(&Decimal.to_float/1)

    avg_f1 = if length(pattern_f1_scores) > 0 do
      Enum.sum(pattern_f1_scores) / length(pattern_f1_scores)
    else
      0
    end

    best_f1 = Enum.max(pattern_f1_scores, fn -> 0 end)

    # Discovery batches count
    batches = list_discovery_batches(limit: 100)
    total_batches = length(batches)

    # Candidate stats
    candidate_stats = investigation_stats()

    %{
      confirmed_insiders: %{
        total: total_insiders,
        trained: trained_insiders,
        untrained: total_insiders - trained_insiders
      },
      baselines: %{
        total: length(baselines),
        with_insider_data: Enum.count(baselines, & &1.insider_sample_count && &1.insider_sample_count > 0),
        avg_separation_score: Float.round(avg_separation, 4)
      },
      patterns: %{
        total: length(patterns),
        avg_f1_score: Float.round(avg_f1, 4),
        best_f1_score: Float.round(best_f1, 4)
      },
      discovery: %{
        total_batches: total_batches,
        total_candidates: candidate_stats.total,
        resolved: candidate_stats.resolved
      }
    }
  end

  @doc """
  Mark confirmed insiders as used for training.

  This prevents double-counting when calculating insider baselines.
  """
  def mark_insiders_for_training do
    # Get unprocessed confirmed insiders
    untrained = from(ci in ConfirmedInsider,
      where: ci.used_for_training == false
    ) |> Repo.all()

    marked = Enum.map(untrained, fn insider ->
      insider
      |> ConfirmedInsider.changeset(%{used_for_training: true})
      |> Repo.update()
    end)

    newly_marked = Enum.count(marked, &match?({:ok, _}, &1))

    {:ok, %{
      newly_marked: newly_marked,
      total_trained: from(ci in ConfirmedInsider, where: ci.used_for_training == true) |> Repo.aggregate(:count)
    }}
  end

  @doc """
  Re-score all trades with current baselines.

  This is an expensive operation - use after baseline updates.

  ## Options

  - `:batch_size` - Trades to process per batch (default: 500)
  - `:limit` - Max trades to re-score (default: all)
  """
  def rescore_all_trades(opts \\ []) do
    batch_size = Keyword.get(opts, :batch_size, 500)
    limit = Keyword.get(opts, :limit)

    Logger.info("Re-scoring trades with updated baselines...")

    # Get all trades that have been scored
    query = from(t in Trade,
      join: ts in TradeScore, on: ts.trade_id == t.id,
      where: not is_nil(t.market_id),
      select: t,
      order_by: [desc: t.trade_timestamp]
    )

    query = if limit, do: from(q in query, limit: ^limit), else: query

    trades = Repo.all(query)
    total = length(trades)

    Logger.info("Re-scoring #{total} trades in batches of #{batch_size}")

    # Process in batches
    results = trades
      |> Enum.chunk_every(batch_size)
      |> Enum.with_index()
      |> Enum.flat_map(fn {batch, idx} ->
        Logger.debug("Processing batch #{idx + 1}/#{ceil(total / batch_size)}")

        Enum.map(batch, fn trade ->
          case score_trade(trade) do
            {:ok, _score} -> :ok
            {:error, _reason} -> :error
          end
        end)
      end)

    scored = Enum.count(results, &(&1 == :ok))
    errors = Enum.count(results, &(&1 == :error))

    Logger.info("Re-scoring complete: #{scored} succeeded, #{errors} errors")

    {:ok, %{
      scored: scored,
      errors: errors,
      total: total
    }}
  end

  @doc """
  Compare two feedback loop iterations.

  Shows improvement metrics between iterations.
  """
  def compare_iterations(pre_stats, post_stats) do
    calculate_improvements(pre_stats, post_stats)
  end

  defp calculate_improvements(pre, post) do
    separation_delta = post.baselines.avg_separation_score - pre.baselines.avg_separation_score
    f1_delta = post.patterns.avg_f1_score - pre.patterns.avg_f1_score
    insider_delta = post.confirmed_insiders.total - pre.confirmed_insiders.total
    candidate_delta = post.discovery.total_candidates - pre.discovery.total_candidates

    %{
      baseline_separation_delta: Float.round(separation_delta, 4),
      pattern_avg_f1_delta: Float.round(f1_delta, 4),
      new_confirmed_insiders: insider_delta,
      new_candidates: candidate_delta,
      improvement_summary: summarize_improvements(separation_delta, f1_delta)
    }
  end

  defp summarize_improvements(sep_delta, f1_delta) do
    cond do
      sep_delta > 0.1 and f1_delta > 0.05 -> "significant_improvement"
      sep_delta > 0.05 or f1_delta > 0.02 -> "moderate_improvement"
      sep_delta > 0 or f1_delta > 0 -> "slight_improvement"
      sep_delta == 0 and f1_delta == 0 -> "no_change"
      true -> "regression"
    end
  end

  @doc """
  Get the number of feedback loop iterations run.
  """
  def get_iteration_count do
    # Count discovery batches with feedback loop notes
    from(db in DiscoveryBatch,
      where: ilike(db.notes, "%feedback%") or ilike(db.notes, "%iteration%")
    ) |> Repo.aggregate(:count)
  end

  @doc """
  Quick confirmation workflow: resolve candidate as insider and run mini feedback loop.

  Useful for confirming candidates one at a time with immediate feedback.

  ## Options

  - `:confidence` - "confirmed" or "likely" (default: "likely")
  - `:source` - Confirmation source (default: "investigation")
  - `:evidence` - Evidence map
  - `:notes` - Investigation notes
  - `:resolved_by` - Investigator identifier
  - `:run_feedback` - Whether to run mini feedback loop (default: false)

  ## Example

      {:ok, result} = Polymarket.confirm_candidate_as_insider(
        candidate_id,
        confidence: "confirmed",
        notes: "Matched news report timing",
        run_feedback: true
      )
  """
  def confirm_candidate_as_insider(candidate_id, opts \\ []) do
    confidence = Keyword.get(opts, :confidence, "likely")
    source = Keyword.get(opts, :source, "investigation")
    evidence = Keyword.get(opts, :evidence, %{})
    notes = Keyword.get(opts, :notes)
    resolved_by = Keyword.get(opts, :resolved_by)
    run_feedback = Keyword.get(opts, :run_feedback, false)

    resolution = if confidence == "confirmed", do: "confirmed_insider", else: "likely_insider"

    case get_investigation_candidate(candidate_id) do
      nil ->
        {:error, :not_found}

      candidate ->
        # Resolve the candidate
        {:ok, resolved} = resolve_candidate(candidate, resolution,
          evidence: Map.put(evidence, "source", source),
          notes: notes,
          resolved_by: resolved_by
        )

        result = %{
          candidate: resolved,
          confirmation: %{
            confidence: confidence,
            source: source
          }
        }

        # Optionally run mini feedback loop
        if run_feedback do
          {:ok, feedback_result} = run_feedback_loop(
            rescore_trades: false,
            discovery_limit: 20,
            notes: "Mini feedback after confirming candidate #{candidate_id}"
          )

          {:ok, Map.put(result, :feedback_loop, feedback_result)}
        else
          {:ok, result}
        end
    end
  end

  @doc """
  Get feedback loop history showing iteration progress over time.
  """
  def feedback_loop_history do
    batches = from(db in DiscoveryBatch,
      where: ilike(db.notes, "%feedback%") or ilike(db.notes, "%iteration%"),
      order_by: [asc: db.started_at]
    ) |> Repo.all()

    Enum.map(batches, fn batch ->
      %{
        batch_id: batch.batch_id,
        started_at: batch.started_at,
        completed_at: batch.completed_at,
        candidates_generated: batch.candidates_generated,
        top_score: batch.top_candidate_score,
        median_score: batch.median_candidate_score,
        notes: batch.notes
      }
    end)
  end

  @doc """
  Recommendation engine: suggest next actions based on current state.

  Analyzes the feedback loop state and suggests optimal next steps.
  """
  def feedback_loop_recommendations do
    stats = feedback_loop_stats()

    recommendations = []

    # Check if we have untrained insiders
    recommendations = if stats.confirmed_insiders.untrained > 0 do
      [{:high, "Run feedback loop - #{stats.confirmed_insiders.untrained} new confirmed insiders not yet incorporated"} | recommendations]
    else
      recommendations
    end

    # Check if we have pending investigations
    inv_stats = investigation_stats()
    undiscovered = Map.get(inv_stats.by_status, "undiscovered", 0)
    critical = Map.get(inv_stats.by_priority, "critical", 0)

    recommendations = if critical > 0 do
      [{:critical, "#{critical} critical priority candidates need investigation"} | recommendations]
    else
      recommendations
    end

    recommendations = if undiscovered > 10 do
      [{:medium, "#{undiscovered} candidates in queue - continue investigations"} | recommendations]
    else
      recommendations
    end

    # Check baseline quality
    recommendations = if stats.baselines.with_insider_data < 3 do
      [{:high, "Need more confirmed insiders for robust baselines (current: #{stats.confirmed_insiders.total})"} | recommendations]
    else
      recommendations
    end

    # Check pattern quality
    recommendations = if stats.patterns.avg_f1_score < 0.3 do
      [{:medium, "Pattern F1 scores low (#{stats.patterns.avg_f1_score}) - consider adding new patterns"} | recommendations]
    else
      recommendations
    end

    # Check if ready for new discovery
    recommendations = if stats.confirmed_insiders.trained >= 3 and undiscovered < 5 do
      [{:medium, "Good time for new discovery run - queue is low"} | recommendations]
    else
      recommendations
    end

    %{
      recommendations: Enum.reverse(recommendations),
      stats: stats,
      ready_for_feedback_loop: stats.confirmed_insiders.untrained > 0
    }
  end

  # ============================================
  # Phase 10: Real-Time Monitoring & Alerts
  # ============================================

  @doc """
  List alerts with optional filtering.

  ## Options

  - `:status` - Filter by status (new, acknowledged, investigating, resolved, dismissed)
  - `:severity` - Filter by severity (low, medium, high, critical)
  - `:wallet_address` - Filter by wallet
  - `:since` - Only alerts after this DateTime
  - `:limit` - Max results (default: 50)

  ## Example

      alerts = Polymarket.list_alerts(status: "new", severity: "critical")
  """
  def list_alerts(opts \\ []) do
    status = Keyword.get(opts, :status)
    severity = Keyword.get(opts, :severity)
    wallet = Keyword.get(opts, :wallet_address)
    since = Keyword.get(opts, :since)
    limit = Keyword.get(opts, :limit, 50)

    query = from(a in Alert, order_by: [desc: a.triggered_at])

    query = if status, do: from(q in query, where: q.status == ^status), else: query
    query = if severity, do: from(q in query, where: q.severity == ^severity), else: query
    query = if wallet, do: from(q in query, where: q.wallet_address == ^wallet), else: query
    query = if since, do: from(q in query, where: q.triggered_at > ^since), else: query
    query = from(q in query, limit: ^limit)

    Repo.all(query)
  end

  @doc """
  Get a specific alert by ID or alert_id string.
  """
  def get_alert(id) when is_integer(id) do
    Repo.get(Alert, id)
  end

  def get_alert(alert_id) when is_binary(alert_id) do
    Repo.get_by(Alert, alert_id: alert_id)
  end

  @doc """
  Acknowledge an alert.

  Marks alert as seen and assigns to investigator.
  """
  def acknowledge_alert(%Alert{} = alert, acknowledged_by) do
    alert
    |> Alert.changeset(%{
      status: "acknowledged",
      acknowledged_at: DateTime.utc_now(),
      acknowledged_by: acknowledged_by
    })
    |> Repo.update()
  end

  @doc """
  Start investigation of an alert.

  Transitions alert to investigating status.
  """
  def investigate_alert(%Alert{} = alert, investigator \\ nil) do
    attrs = %{status: "investigating"}
    attrs = if investigator, do: Map.put(attrs, :acknowledged_by, investigator), else: attrs

    attrs = if is_nil(alert.acknowledged_at) do
      Map.put(attrs, :acknowledged_at, DateTime.utc_now())
    else
      attrs
    end

    alert
    |> Alert.changeset(attrs)
    |> Repo.update()
  end

  @doc """
  Resolve an alert with resolution details.

  ## Resolutions

  - `confirmed_insider` - Confirmed as insider trading
  - `likely_insider` - Likely insider, not fully confirmed
  - `false_positive` - Not actually suspicious
  - `inconclusive` - Unable to determine

  ## Example

      Polymarket.resolve_alert(alert, "confirmed_insider",
        notes: "Matched timing with news release"
      )
  """
  def resolve_alert(%Alert{} = alert, resolution, opts \\ []) do
    notes = Keyword.get(opts, :notes)

    alert
    |> Alert.changeset(%{
      status: "resolved",
      resolution: resolution,
      resolution_notes: notes
    })
    |> Repo.update()
  end

  @doc """
  Dismiss an alert as not requiring action.
  """
  def dismiss_alert(%Alert{} = alert, reason \\ nil) do
    alert
    |> Alert.changeset(%{
      status: "dismissed",
      resolution: "dismissed",
      resolution_notes: reason
    })
    |> Repo.update()
  end

  @doc """
  Get alert statistics dashboard.
  """
  def alert_stats do
    alerts = Repo.all(Alert)

    by_status = alerts
      |> Enum.group_by(& &1.status)
      |> Enum.map(fn {k, v} -> {k, length(v)} end)
      |> Map.new()

    by_severity = alerts
      |> Enum.group_by(& &1.severity)
      |> Enum.map(fn {k, v} -> {k, length(v)} end)
      |> Map.new()

    by_type = alerts
      |> Enum.group_by(& &1.alert_type)
      |> Enum.map(fn {k, v} -> {k, length(v)} end)
      |> Map.new()

    recent = alerts
      |> Enum.filter(fn a ->
        case a.triggered_at do
          nil -> false
          ts -> DateTime.diff(DateTime.utc_now(), ts, :hour) < 24
        end
      end)
      |> length()

    %{
      total: length(alerts),
      by_status: by_status,
      by_severity: by_severity,
      by_type: by_type,
      new: Map.get(by_status, "new", 0),
      critical: Map.get(by_severity, "critical", 0),
      last_24h: recent
    }
  end

  @doc """
  Create a manual alert for a trade.

  Used when manual investigation identifies suspicious activity.
  """
  def create_manual_alert(trade_id, opts \\ []) do
    trade = Repo.get(Trade, trade_id)
    score = from(ts in TradeScore, where: ts.trade_id == ^trade_id) |> Repo.one()
    market = if trade && trade.market_id, do: Repo.get(Market, trade.market_id)

    severity = Keyword.get(opts, :severity, "medium")
    notes = Keyword.get(opts, :notes)

    attrs = %{
      alert_id: Alert.generate_alert_id(trade_id),
      alert_type: "manual",
      trade_id: trade_id,
      trade_score_id: score && score.id,
      market_id: trade && trade.market_id,
      transaction_hash: trade && trade.transaction_hash,
      wallet_address: trade && trade.wallet_address,
      condition_id: trade && trade.condition_id,
      severity: severity,
      anomaly_score: score && score.anomaly_score,
      insider_probability: score && score.insider_probability,
      market_question: market && market.question,
      trade_size: trade && trade.size,
      trade_outcome: trade && trade.outcome,
      trade_price: trade && trade.price,
      triggered_at: DateTime.utc_now(),
      trade_timestamp: trade && trade.trade_timestamp,
      resolution_notes: notes
    }

    %Alert{}
    |> Alert.changeset(attrs)
    |> Repo.insert()
  end

  @doc """
  Convert an alert to an investigation candidate.

  Promotes alert to full investigation workflow.
  """
  def promote_alert_to_candidate(%Alert{} = alert) do
    # Check if candidate already exists for this trade
    existing = if alert.trade_id do
      from(ic in InvestigationCandidate, where: ic.trade_id == ^alert.trade_id)
      |> Repo.one()
    end

    if existing do
      {:error, :candidate_exists}
    else
      # Get trade score for additional details
      score = if alert.trade_score_id, do: Repo.get(TradeScore, alert.trade_score_id)

      attrs = %{
        trade_id: alert.trade_id,
        trade_score_id: alert.trade_score_id,
        market_id: alert.market_id,
        transaction_hash: alert.transaction_hash,
        wallet_address: alert.wallet_address,
        condition_id: alert.condition_id,
        discovery_rank: 0,  # Manual promotion, no rank
        anomaly_score: alert.anomaly_score || Decimal.new("0"),
        insider_probability: alert.insider_probability || Decimal.new("0"),
        market_question: alert.market_question,
        trade_size: alert.trade_size,
        trade_outcome: alert.trade_outcome,
        anomaly_breakdown: score && InvestigationCandidate.build_anomaly_breakdown(score),
        matched_patterns: alert.matched_patterns,
        priority: InvestigationCandidate.calculate_priority(alert.insider_probability),
        batch_id: "alert_promotion",
        discovered_at: DateTime.utc_now()
      }

      with {:ok, candidate} <- %InvestigationCandidate{}
           |> InvestigationCandidate.changeset(attrs)
           |> Repo.insert(),
           {:ok, _alert} <- resolve_alert(alert, "promoted_to_candidate") do
        {:ok, candidate}
      end
    end
  end

  @doc """
  Get real-time monitoring dashboard data.

  Combines alert stats, recent activity, and system status.
  """
  def monitoring_dashboard do
    alert_statistics = alert_stats()
    investigation_statistics = investigation_stats()

    # Get recent alerts
    recent_alerts = list_alerts(limit: 10)

    # Get critical items
    critical_alerts = list_alerts(status: "new", severity: "critical")
    high_alerts = list_alerts(status: "new", severity: "high")

    %{
      alerts: alert_statistics,
      investigations: investigation_statistics,
      recent_alerts: Enum.map(recent_alerts, fn a ->
        %{
          id: a.id,
          alert_id: a.alert_id,
          severity: a.severity,
          status: a.status,
          wallet: a.wallet_address,
          market: a.market_question,
          score: a.insider_probability,
          triggered_at: a.triggered_at
        }
      end),
      action_required: %{
        critical_alerts: length(critical_alerts),
        high_alerts: length(high_alerts),
        pending_investigations: Map.get(investigation_statistics.by_status, "undiscovered", 0)
      },
      monitor_status: try do
        TradeMonitor.status()
      catch
        :exit, _ -> %{enabled: false, error: "Monitor not running"}
      end
    }
  end
end
