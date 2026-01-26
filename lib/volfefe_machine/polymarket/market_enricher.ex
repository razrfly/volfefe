defmodule VolfefeMachine.Polymarket.MarketEnricher do
  @moduledoc """
  Market metadata enrichment for stub markets.

  Stub markets are created during trade ingestion when we encounter unknown tokens.
  They have synthetic condition_ids (`token_XXXX`) and placeholder metadata.

  This module enriches stub markets by:
  1. Fetching market metadata from CLOB API (requires VPN for US users)
  2. Building token_id → market metadata mapping
  3. Updating stub markets with full metadata (question, end_date, category)

  ## Why This Matters

  Resolution dates are critical for insider timing analysis. Without them,
  we can't detect pre-resolution trading patterns (a key insider signal).

  ## VPN Requirement

  Polymarket geo-blocks US IP addresses. To use CLOB API enrichment,
  you must connect via VPN to a non-US location.

  ## Usage

      # Enrich all stub markets using CLOB API (requires VPN)
      MarketEnricher.enrich_from_clob_api()

      # Enrich using subgraph only (no VPN needed, limited metadata)
      MarketEnricher.enrich_all_stub_markets()

      # Get enrichment stats
      MarketEnricher.get_enrichment_stats()
  """

  require Logger
  import Ecto.Query
  alias VolfefeMachine.Repo
  alias VolfefeMachine.Polymarket.{Market, Trade, SubgraphClient, VpnClient}

  @clob_api_base "https://clob.polymarket.com"
  @gamma_api_base "https://gamma-api.polymarket.com"
  @http_timeout 60_000

  @doc """
  Enrich stub markets using CLOB API (requires VPN for US users).

  This fetches full market metadata including:
  - question, description
  - end_date (critical for insider timing analysis)
  - category/tags
  - token_id mappings

  ## Options

  - `:max_pages` - Maximum CLOB API pages to fetch (default: 100, ~1000 markets)
  - `:batch_size` - Markets per API request (default: 100)
  - `:dry_run` - If true, don't make changes (default: false)

  ## Returns

  `{:ok, stats}` or `{:error, reason}`
  """
  def enrich_from_clob_api(opts \\ []) do
    max_pages = Keyword.get(opts, :max_pages, 100)
    batch_size = Keyword.get(opts, :batch_size, 100)
    dry_run = Keyword.get(opts, :dry_run, false)

    Logger.info("[MarketEnricher] Starting CLOB API enrichment, max_pages=#{max_pages}, dry_run=#{dry_run}")

    # Step 1: Fetch markets from CLOB API and build token mapping
    case build_clob_token_mapping(max_pages: max_pages, batch_size: batch_size) do
      {:ok, token_mapping} ->
        Logger.info("[MarketEnricher] Built CLOB mapping with #{map_size(token_mapping)} token entries")

        # Step 2: Get stub markets
        stub_markets = get_stub_markets(:all)
        Logger.info("[MarketEnricher] Found #{length(stub_markets)} stub markets to process")

        # Step 3: Enrich each stub market
        results = Enum.reduce(stub_markets, %{enriched: 0, unchanged: 0, errors: 0}, fn market, acc ->
          case enrich_from_clob_mapping(market, token_mapping, dry_run) do
            :enriched -> %{acc | enriched: acc.enriched + 1}
            :unchanged -> %{acc | unchanged: acc.unchanged + 1}
            :error -> %{acc | errors: acc.errors + 1}
          end
        end)

        Logger.info("[MarketEnricher] CLOB enrichment complete: enriched=#{results.enriched}, unchanged=#{results.unchanged}, errors=#{results.errors}")
        {:ok, results}
    end
  end

  @doc """
  Enrich markets with real condition_ids using Gamma API.

  This is the second phase of enrichment:
  1. Subgraph maps token_id → condition_id (done by enrich_all_stub_markets)
  2. Gamma API maps condition_id → full metadata (this function)

  Gamma API returns question, end_date, description, outcomes, etc.
  Requires VPN for US users.

  ## Options

  - `:batch_size` - Condition IDs per API request (default: 50)
  - `:dry_run` - If true, don't make changes (default: false)
  """
  def enrich_from_gamma_api(opts \\ []) do
    batch_size = Keyword.get(opts, :batch_size, 50)
    dry_run = Keyword.get(opts, :dry_run, false)

    Logger.info("[MarketEnricher] Starting Gamma API enrichment, dry_run=#{dry_run}")

    # Get markets that have real condition_ids but still need metadata
    markets_needing_metadata = get_markets_needing_metadata()
    Logger.info("[MarketEnricher] Found #{length(markets_needing_metadata)} markets needing metadata")

    if length(markets_needing_metadata) == 0 do
      {:ok, %{enriched: 0, unchanged: 0, errors: 0, not_found: 0}}
    else
      # Group markets by condition_id for batch API calls
      markets_by_cid = Enum.group_by(markets_needing_metadata, & &1.condition_id)
      condition_ids = Map.keys(markets_by_cid)

      # Fetch metadata in batches
      results = condition_ids
      |> Enum.chunk_every(batch_size)
      |> Enum.with_index()
      |> Enum.reduce(%{enriched: 0, unchanged: 0, errors: 0, not_found: 0}, fn {batch_cids, idx}, acc ->
        Logger.debug("[MarketEnricher] Fetching Gamma batch #{idx + 1}")

        case fetch_gamma_markets(batch_cids) do
          {:ok, gamma_markets} ->
            # Build condition_id -> metadata map from response
            metadata_map = Enum.reduce(gamma_markets, %{}, fn m, acc2 ->
              Map.put(acc2, m["conditionId"], m)
            end)

            # Enrich each market
            Enum.reduce(batch_cids, acc, fn cid, acc2 ->
              markets = Map.get(markets_by_cid, cid, [])

              case Map.get(metadata_map, cid) do
                nil ->
                  # Not found in Gamma API
                  %{acc2 | not_found: acc2.not_found + length(markets)}

                gamma_data ->
                  # Apply enrichment to all markets with this condition_id
                  Enum.reduce(markets, acc2, fn market, acc3 ->
                    if dry_run do
                      Logger.debug("[MarketEnricher] Would enrich market #{market.id}: #{gamma_data["question"]}")
                      %{acc3 | enriched: acc3.enriched + 1}
                    else
                      case apply_gamma_enrichment(market, gamma_data) do
                        :enriched -> %{acc3 | enriched: acc3.enriched + 1}
                        :error -> %{acc3 | errors: acc3.errors + 1}
                      end
                    end
                  end)
              end
            end)

          {:error, reason} ->
            Logger.warning("[MarketEnricher] Gamma API error: #{inspect(reason)}")
            %{acc | errors: acc.errors + length(batch_cids)}
        end
      end)

      Logger.info("[MarketEnricher] Gamma enrichment complete: #{inspect(results)}")
      {:ok, results}
    end
  end

  defp get_markets_needing_metadata do
    Repo.all(
      from m in Market,
      where: not like(m.condition_id, "token_%") and
             fragment("?->>'needs_metadata' = 'true'", m.meta)
    )
  end

  defp fetch_gamma_markets(condition_ids) when is_list(condition_ids) do
    # Gamma API requires repeated params: condition_ids=X&condition_ids=Y
    # Requires VPN for US users (geo-blocked)
    params = Enum.map(condition_ids, fn cid -> "condition_ids=#{cid}" end)
    query_string = Enum.join(params, "&")
    url = "#{@gamma_api_base}/markets?#{query_string}"

    case VpnClient.get(url, receive_timeout: @http_timeout) do
      {:ok, %{status: 200, body: body}} when is_list(body) ->
        {:ok, body}

      {:ok, %{status: status}} ->
        {:error, "Gamma API returned status #{status}"}

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp apply_gamma_enrichment(market, gamma_data) do
    Logger.debug("[MarketEnricher] Enriching market #{market.id} with Gamma data")

    # Parse end_date
    end_date = parse_end_date(gamma_data["endDate"])

    # Parse outcomes
    outcomes = case gamma_data["outcomes"] do
      s when is_binary(s) ->
        case Jason.decode(s) do
          {:ok, list} when is_list(list) -> %{"options" => list}
          _ -> nil
        end
      list when is_list(list) -> %{"options" => list}
      _ -> nil
    end

    # Parse outcome prices
    outcome_prices = case {gamma_data["outcomePrices"], outcomes} do
      {s, %{"options" => opts}} when is_binary(s) ->
        case Jason.decode(s) do
          {:ok, prices} when is_list(prices) ->
            Enum.zip(opts, prices) |> Enum.into(%{}, fn {o, p} -> {o, to_string(p)} end)
          _ -> nil
        end
      _ -> nil
    end

    # Infer category from events or slug
    category = infer_category_from_gamma(gamma_data)

    attrs = %{
      question: gamma_data["question"] || market.question,
      description: gamma_data["description"],
      end_date: end_date,
      slug: gamma_data["slug"],
      category: category || market.category,
      outcomes: outcomes || market.outcomes,
      outcome_prices: outcome_prices || market.outcome_prices,
      volume: parse_decimal(gamma_data["volume"]),
      liquidity: parse_decimal(gamma_data["liquidity"]),
      is_active: gamma_data["active"] == true,
      meta: Map.merge(market.meta || %{}, %{
        "enriched_at" => DateTime.utc_now() |> DateTime.to_iso8601(),
        "enrichment_source" => "gamma_api",
        "needs_metadata" => false
      })
    }

    case market |> Market.changeset(attrs) |> Repo.update() do
      {:ok, _} -> :enriched
      {:error, changeset} ->
        Logger.warning("[MarketEnricher] Gamma enrichment failed for market #{market.id}: #{inspect(changeset.errors)}")
        :error
    end
  end

  defp infer_category_from_gamma(gamma_data) do
    # Try to infer from events or slug
    events = gamma_data["events"] || []
    slug = gamma_data["slug"] || ""
    question = String.downcase(gamma_data["question"] || "")

    cond do
      String.contains?(question, "bitcoin") or String.contains?(slug, "bitcoin") -> :crypto
      String.contains?(question, "ethereum") or String.contains?(slug, "ethereum") -> :crypto
      String.contains?(question, "crypto") -> :crypto
      String.contains?(question, "president") or String.contains?(question, "election") -> :politics
      String.contains?(question, "trump") or String.contains?(question, "biden") -> :politics
      String.contains?(question, "nba") or String.contains?(question, "nfl") -> :sports
      String.contains?(question, "ncaa") or String.contains?(slug, "ncaa") -> :sports
      Enum.any?(events, fn e -> String.contains?(e["slug"] || "", "sport") end) -> :sports
      true -> :other
    end
  end

  defp parse_decimal(nil), do: nil
  defp parse_decimal(val) when is_float(val), do: Decimal.from_float(val)
  defp parse_decimal(val) when is_integer(val), do: Decimal.new(val)
  defp parse_decimal(val) when is_binary(val) do
    case Decimal.parse(val) do
      {decimal, ""} -> decimal
      {decimal, _} -> decimal
      :error -> nil
    end
  end

  @doc """
  Get statistics about stub markets and enrichment potential.
  """
  def get_enrichment_stats do
    total_markets = Repo.aggregate(Market, :count)

    stub_count = Repo.one(
      from m in Market,
      where: like(m.condition_id, "token_%"),
      select: count()
    )

    needs_enrichment = Repo.one(
      from m in Market,
      where: fragment("?->>'needs_metadata' = 'true'", m.meta),
      select: count()
    )

    has_end_date = Repo.one(
      from m in Market,
      where: not is_nil(m.end_date),
      select: count()
    )

    has_real_question = Repo.one(
      from m in Market,
      where: not like(m.question, "[Unknown%"),
      select: count()
    )

    %{
      total_markets: total_markets,
      stub_markets: stub_count,
      needs_enrichment: needs_enrichment,
      has_end_date: has_end_date,
      has_real_question: has_real_question,
      enrichment_coverage: if(total_markets > 0, do: Float.round((has_end_date / total_markets) * 100, 1), else: 0)
    }
  end

  @doc """
  Enrich all stub markets using available data sources.

  Returns statistics about the enrichment process.

  ## Options

  - `:batch_size` - Process in batches (default: 100)
  - `:max_markets` - Maximum markets to process (default: all)
  - `:dry_run` - If true, don't make changes (default: false)
  """
  def enrich_all_stub_markets(opts \\ []) do
    batch_size = Keyword.get(opts, :batch_size, 100)
    max_markets = Keyword.get(opts, :max_markets, :all)
    dry_run = Keyword.get(opts, :dry_run, false)

    Logger.info("[MarketEnricher] Starting enrichment, batch_size=#{batch_size}, dry_run=#{dry_run}")

    # Step 1: Build subgraph token mapping
    {:ok, token_mapping} = build_subgraph_mapping()
    Logger.info("[MarketEnricher] Built mapping with #{map_size(token_mapping)} token entries")

    # Step 2: Get all stub markets
    stub_markets = get_stub_markets(max_markets)
    Logger.info("[MarketEnricher] Found #{length(stub_markets)} stub markets to process")

    # Step 3: Process in batches
    results = stub_markets
    |> Enum.chunk_every(batch_size)
    |> Enum.with_index()
    |> Enum.reduce(%{merged: 0, updated: 0, unchanged: 0, errors: 0}, fn {batch, idx}, acc ->
      Logger.debug("[MarketEnricher] Processing batch #{idx + 1}")

      batch_results = Enum.map(batch, fn market ->
        enrich_single_market(market, token_mapping, dry_run)
      end)

      Enum.reduce(batch_results, acc, fn result, acc2 ->
        case result do
          :merged -> %{acc2 | merged: acc2.merged + 1}
          :updated -> %{acc2 | updated: acc2.updated + 1}
          :unchanged -> %{acc2 | unchanged: acc2.unchanged + 1}
          :error -> %{acc2 | errors: acc2.errors + 1}
        end
      end)
    end)

    Logger.info("[MarketEnricher] Complete: merged=#{results.merged}, updated=#{results.updated}, unchanged=#{results.unchanged}, errors=#{results.errors}")

    {:ok, results}
  end

  @doc """
  Enrich a single market by ID.
  """
  def enrich_market(market_id) when is_integer(market_id) do
    case Repo.get(Market, market_id) do
      nil -> {:error, :not_found}
      market ->
        {:ok, token_mapping} = build_subgraph_mapping(limit: 10_000)
        result = enrich_single_market(market, token_mapping, false)
        {:ok, result}
    end
  end

  # ============================================
  # Private Functions
  # ============================================

  defp build_subgraph_mapping(opts \\ []) do
    limit = Keyword.get(opts, :limit, 50_000)

    Logger.debug("[MarketEnricher] Building subgraph mapping, limit=#{limit}")

    # Fetch mappings in batches
    mappings = Stream.unfold(0, fn skip ->
      if skip >= limit do
        nil
      else
        case SubgraphClient.get_market_data_mappings(limit: 1000, skip: skip) do
          {:ok, []} -> nil
          {:ok, batch} -> {batch, skip + 1000}
          {:error, reason} ->
            Logger.warning("[MarketEnricher] Subgraph fetch error at skip=#{skip}: #{inspect(reason)}")
            nil
        end
      end
    end)
    |> Enum.to_list()
    |> List.flatten()

    # Build token_id -> {condition_id, outcome_index} map
    mapping = Enum.reduce(mappings, %{}, fn m, acc ->
      Map.put(acc, m.token_id, %{
        condition_id: m.condition_id,
        outcome_index: m.outcome_index
      })
    end)

    {:ok, mapping}
  end

  defp get_stub_markets(:all) do
    Repo.all(
      from m in Market,
      where: like(m.condition_id, "token_%"),
      order_by: [desc: m.inserted_at]
    )
  end

  defp get_stub_markets(limit) when is_integer(limit) do
    Repo.all(
      from m in Market,
      where: like(m.condition_id, "token_%"),
      order_by: [desc: m.inserted_at],
      limit: ^limit
    )
  end

  defp enrich_single_market(market, token_mapping, dry_run) do
    # Get token_id from market meta
    token_id = get_in(market.meta || %{}, ["token_id"])

    if is_nil(token_id) do
      Logger.debug("[MarketEnricher] Market #{market.id} has no token_id in meta")
      :unchanged
    else
      case Map.get(token_mapping, token_id) do
        nil ->
          # No mapping found in subgraph
          :unchanged

        %{condition_id: real_condition_id} ->
          # Found real condition_id, check if we have an existing market with metadata
          handle_condition_id_match(market, real_condition_id, dry_run)
      end
    end
  end

  defp handle_condition_id_match(stub_market, real_condition_id, dry_run) do
    # Look for existing market with this condition_id that has metadata
    existing = Repo.one(
      from m in Market,
      where: m.condition_id == ^real_condition_id and m.id != ^stub_market.id,
      limit: 1
    )

    cond do
      # Case 1: Existing market with full metadata - merge
      existing && has_metadata?(existing) ->
        if dry_run do
          Logger.debug("[MarketEnricher] Would merge market #{stub_market.id} into #{existing.id}")
          :merged
        else
          merge_markets(stub_market, existing)
        end

      # Case 2: Existing market without metadata - just update condition_id
      existing ->
        if dry_run do
          Logger.debug("[MarketEnricher] Would update market #{stub_market.id} condition_id (existing #{existing.id} has no metadata)")
          :updated
        else
          update_condition_id(stub_market, real_condition_id)
        end

      # Case 3: No existing market - update stub with real condition_id
      true ->
        if dry_run do
          Logger.debug("[MarketEnricher] Would update market #{stub_market.id} with real condition_id #{String.slice(real_condition_id, 0..20)}...")
          :updated
        else
          update_condition_id(stub_market, real_condition_id)
        end
    end
  end

  defp has_metadata?(market) do
    # Market has metadata if it has end_date and a real question
    not is_nil(market.end_date) and
      not String.starts_with?(market.question || "", "[Unknown")
  end

  defp merge_markets(stub_market, target_market) do
    Logger.info("[MarketEnricher] Merging market #{stub_market.id} into #{target_market.id}")

    Repo.transaction(fn ->
      # Move all trades from stub to target
      trade_count = Repo.update_all(
        from(t in Trade, where: t.market_id == ^stub_market.id),
        set: [market_id: target_market.id]
      )
      |> elem(0)

      Logger.debug("[MarketEnricher] Moved #{trade_count} trades from market #{stub_market.id} to #{target_market.id}")

      # Update target market meta to note the merge
      merged_tokens = [
        get_in(stub_market.meta || %{}, ["token_id"]) |
        get_in(target_market.meta || %{}, ["merged_tokens"]) || []
      ] |> Enum.filter(& &1)

      updated_meta = Map.merge(target_market.meta || %{}, %{
        "merged_tokens" => merged_tokens,
        "last_merge" => DateTime.utc_now() |> DateTime.to_iso8601()
      })

      target_market
      |> Market.changeset(%{meta: updated_meta})
      |> Repo.update!()

      # Delete the stub market
      Repo.delete!(stub_market)

      :merged
    end)
    |> case do
      {:ok, result} -> result
      {:error, reason} ->
        Logger.error("[MarketEnricher] Merge failed for market #{stub_market.id}: #{inspect(reason)}")
        :error
    end
  end

  defp update_condition_id(market, real_condition_id) do
    Logger.debug("[MarketEnricher] Updating market #{market.id} condition_id to #{String.slice(real_condition_id, 0..20)}...")

    # Update meta to note we've mapped but still need metadata
    updated_meta = Map.merge(market.meta || %{}, %{
      "original_synthetic_id" => market.condition_id,
      "condition_mapped_at" => DateTime.utc_now() |> DateTime.to_iso8601(),
      "needs_metadata" => true,  # Still need question, end_date, etc.
      "needs_condition_mapping" => false  # But we have real condition_id now
    })

    case market
         |> Market.changeset(%{condition_id: real_condition_id, meta: updated_meta})
         |> Repo.update() do
      {:ok, _} -> :updated
      {:error, changeset} ->
        # Might fail due to unique constraint if condition_id already exists
        Logger.warning("[MarketEnricher] Update failed for market #{market.id}: #{inspect(changeset.errors)}")
        :error
    end
  end

  # ============================================
  # CLOB API Functions
  # ============================================

  defp build_clob_token_mapping(opts) do
    max_pages = Keyword.get(opts, :max_pages, 100)
    batch_size = Keyword.get(opts, :batch_size, 100)

    Logger.info("[MarketEnricher] Fetching markets from CLOB API...")

    # Fetch all markets with pagination
    markets = fetch_clob_markets_paginated(max_pages, batch_size)

    Logger.info("[MarketEnricher] Fetched #{length(markets)} markets from CLOB API")

    # Build token_id -> market_data mapping
    mapping = Enum.reduce(markets, %{}, fn market, acc ->
      tokens = market["tokens"] || []

      Enum.reduce(tokens, acc, fn token, acc2 ->
        token_id = token["token_id"]
        if token_id do
          Map.put(acc2, token_id, %{
            condition_id: market["condition_id"],
            question: market["question"],
            description: market["description"],
            end_date: parse_end_date(market["end_date_iso"]),
            slug: market["market_slug"],
            category: infer_category(market["tags"] || []),
            outcomes: extract_outcomes(tokens),
            outcome_prices: extract_outcome_prices(tokens),
            token_outcome: token["outcome"]
          })
        else
          acc2
        end
      end)
    end)

    {:ok, mapping}
  end

  defp fetch_clob_markets_paginated(max_pages, batch_size) do
    Stream.unfold(0, fn offset ->
      if offset >= max_pages * batch_size do
        nil
      else
        case fetch_clob_markets(limit: batch_size, offset: offset) do
          {:ok, %{"data" => []}} -> nil
          {:ok, %{"data" => markets}} -> {markets, offset + batch_size}
          {:ok, markets} when is_list(markets) -> {markets, offset + batch_size}
          {:error, reason} ->
            Logger.warning("[MarketEnricher] CLOB API error at offset=#{offset}: #{inspect(reason)}")
            nil
        end
      end
    end)
    |> Enum.to_list()
    |> List.flatten()
  end

  defp fetch_clob_markets(opts) do
    # CLOB API requires VPN for US users (geo-blocked)
    limit = Keyword.get(opts, :limit, 100)
    offset = Keyword.get(opts, :offset, 0)

    url = "#{@clob_api_base}/markets?limit=#{limit}&offset=#{offset}"

    case VpnClient.get(url, receive_timeout: @http_timeout) do
      {:ok, %{status: 200, body: body}} ->
        {:ok, body}

      {:ok, %{status: status}} ->
        {:error, "CLOB API returned status #{status}"}

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp enrich_from_clob_mapping(market, token_mapping, dry_run) do
    # Get token_id from market meta
    token_id = get_in(market.meta || %{}, ["token_id"])

    if is_nil(token_id) do
      :unchanged
    else
      case Map.get(token_mapping, token_id) do
        nil ->
          :unchanged

        market_data ->
          if dry_run do
            Logger.debug("[MarketEnricher] Would enrich market #{market.id} with CLOB data: #{market_data.question}")
            :enriched
          else
            apply_clob_enrichment(market, market_data)
          end
      end
    end
  end

  defp apply_clob_enrichment(market, market_data) do
    Logger.debug("[MarketEnricher] Enriching market #{market.id} with CLOB data")

    # Build update attrs
    attrs = %{
      condition_id: market_data.condition_id,
      question: market_data.question || market.question,
      description: market_data.description,
      end_date: market_data.end_date,
      slug: market_data.slug,
      category: market_data.category || market.category,
      outcomes: market_data.outcomes || market.outcomes,
      outcome_prices: market_data.outcome_prices || market.outcome_prices,
      meta: Map.merge(market.meta || %{}, %{
        "original_synthetic_id" => market.condition_id,
        "enriched_at" => DateTime.utc_now() |> DateTime.to_iso8601(),
        "enrichment_source" => "clob_api",
        "needs_metadata" => false,
        "needs_condition_mapping" => false
      })
    }

    case market |> Market.changeset(attrs) |> Repo.update() do
      {:ok, _} -> :enriched
      {:error, changeset} ->
        Logger.warning("[MarketEnricher] CLOB enrichment failed for market #{market.id}: #{inspect(changeset.errors)}")
        :error
    end
  end

  defp parse_end_date(nil), do: nil
  defp parse_end_date(""), do: nil
  defp parse_end_date(date_string) when is_binary(date_string) do
    case DateTime.from_iso8601(date_string) do
      {:ok, dt, _} -> dt
      _ ->
        # Try parsing as date only
        case Date.from_iso8601(String.slice(date_string, 0..9)) do
          {:ok, date} -> DateTime.new!(date, ~T[00:00:00], "Etc/UTC")
          _ -> nil
        end
    end
  end

  defp infer_category(tags) when is_list(tags) do
    tags_lower = Enum.map(tags, &String.downcase/1)

    cond do
      Enum.any?(tags_lower, &String.contains?(&1, "politic")) -> :politics
      Enum.any?(tags_lower, &String.contains?(&1, "crypto")) -> :crypto
      Enum.any?(tags_lower, &String.contains?(&1, "sport")) -> :sports
      Enum.any?(tags_lower, &String.contains?(&1, "nba")) -> :sports
      Enum.any?(tags_lower, &String.contains?(&1, "nfl")) -> :sports
      Enum.any?(tags_lower, &String.contains?(&1, "nhl")) -> :sports
      Enum.any?(tags_lower, &String.contains?(&1, "mlb")) -> :sports
      Enum.any?(tags_lower, &String.contains?(&1, "ncaa")) -> :sports
      Enum.any?(tags_lower, &String.contains?(&1, "soccer")) -> :sports
      Enum.any?(tags_lower, &String.contains?(&1, "finance")) -> :finance
      Enum.any?(tags_lower, &String.contains?(&1, "tech")) -> :tech
      Enum.any?(tags_lower, &String.contains?(&1, "science")) -> :science
      true -> :other
    end
  end
  defp infer_category(_), do: :other

  defp extract_outcomes(tokens) when is_list(tokens) do
    outcomes = Enum.map(tokens, fn t -> t["outcome"] end) |> Enum.filter(& &1)
    if length(outcomes) > 0, do: %{"options" => outcomes}, else: nil
  end
  defp extract_outcomes(_), do: nil

  defp extract_outcome_prices(tokens) when is_list(tokens) do
    Enum.reduce(tokens, %{}, fn t, acc ->
      outcome = t["outcome"]
      price = t["price"]
      if outcome && price do
        Map.put(acc, outcome, to_string(price))
      else
        acc
      end
    end)
  end
  defp extract_outcome_prices(_), do: nil
end
