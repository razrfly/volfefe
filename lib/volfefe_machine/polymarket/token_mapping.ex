defmodule VolfefeMachine.Polymarket.TokenMapping do
  @moduledoc """
  Maps Polymarket condition token IDs to markets.

  The subgraph uses 256-bit condition token IDs (`makerAssetId`/`takerAssetId`)
  which need to be mapped back to our market records for trade association.

  ## Token ID Structure

  Each Polymarket market has multiple token IDs stored in `meta.clobTokenIds`:
  - Token 0: First outcome (typically "Yes" or team A)
  - Token 1: Second outcome (typically "No" or team B)

  These are 256-bit integers stored as decimal strings.

  ## Usage

      # Build mapping from database
      {:ok, mapping} = TokenMapping.build_mapping()

      # Look up market by token ID
      case TokenMapping.lookup(mapping, "1234567890...") do
        {:ok, %{market_id: 1, condition_id: "0x...", outcome_index: 0}} ->
          # Found the market
        :not_found ->
          # Token ID not in our database
      end

      # Get all token IDs for a market
      {:ok, tokens} = TokenMapping.get_market_tokens(market)
  """

  import Ecto.Query
  alias VolfefeMachine.Repo
  alias VolfefeMachine.Polymarket.Market

  @doc """
  Builds a mapping of token IDs to market information.

  Returns a map where:
  - Keys are token ID strings (256-bit decimal)
  - Values are maps with `:market_id`, `:condition_id`, `:outcome_index`

  ## Options

  - `:include_inactive` - Include inactive markets (default: false)

  ## Returns

  - `{:ok, %{token_id => market_info}}`
  - `{:error, reason}`
  """
  def build_mapping(opts \\ []) do
    include_inactive = Keyword.get(opts, :include_inactive, false)

    query = if include_inactive do
      from(m in Market, select: {m.id, m.condition_id, m.meta})
    else
      from(m in Market, where: m.is_active == true or not is_nil(m.resolved_outcome),
           select: {m.id, m.condition_id, m.meta})
    end

    markets = Repo.all(query)

    mapping = Enum.reduce(markets, %{}, fn {market_id, condition_id, meta}, acc ->
      case extract_token_ids(meta) do
        {:ok, token_ids} ->
          token_ids
          |> Enum.with_index()
          |> Enum.reduce(acc, fn {token_id, outcome_index}, inner_acc ->
            Map.put(inner_acc, token_id, %{
              market_id: market_id,
              condition_id: condition_id,
              outcome_index: outcome_index
            })
          end)

        :no_tokens ->
          acc
      end
    end)

    {:ok, mapping}
  end

  @doc """
  Looks up market information by token ID.

  ## Parameters

  - `mapping` - The mapping built by `build_mapping/1`
  - `token_id` - The 256-bit token ID as a string

  ## Returns

  - `{:ok, %{market_id, condition_id, outcome_index}}`
  - `:not_found`
  """
  def lookup(mapping, token_id) when is_binary(token_id) do
    case Map.get(mapping, token_id) do
      nil -> :not_found
      info -> {:ok, info}
    end
  end

  def lookup(mapping, token_id) when is_integer(token_id) do
    lookup(mapping, Integer.to_string(token_id))
  end

  @doc """
  Extracts token IDs from a market's meta field.

  ## Returns

  - `{:ok, [token_id_strings]}`
  - `:no_tokens` if no token IDs found
  """
  def extract_token_ids(nil), do: :no_tokens
  def extract_token_ids(meta) when is_map(meta) do
    case Map.get(meta, "clobTokenIds") do
      nil -> :no_tokens
      json_string when is_binary(json_string) ->
        case Jason.decode(json_string) do
          {:ok, tokens} when is_list(tokens) ->
            # Normalize all token IDs to strings for consistent lookups
            {:ok, Enum.map(tokens, &to_string/1)}
          _ -> :no_tokens
        end
      tokens when is_list(tokens) ->
        # Normalize all token IDs to strings for consistent lookups
        {:ok, Enum.map(tokens, &to_string/1)}
    end
  end

  @doc """
  Gets all token IDs for a specific market.

  ## Parameters

  - `market` - Market struct or market ID

  ## Returns

  - `{:ok, [%{token_id, outcome_index, outcome_name}]}`
  - `{:error, reason}`
  """
  def get_market_tokens(%Market{} = market) do
    case extract_token_ids(market.meta) do
      {:ok, token_ids} ->
        outcomes = get_outcome_names(market)

        tokens =
          token_ids
          |> Enum.with_index()
          |> Enum.map(fn {token_id, idx} ->
            %{
              token_id: token_id,
              outcome_index: idx,
              outcome_name: Enum.at(outcomes, idx, "Outcome #{idx}")
            }
          end)

        {:ok, tokens}

      :no_tokens ->
        {:error, "No token IDs found in market metadata"}
    end
  end

  def get_market_tokens(market_id) when is_integer(market_id) do
    case Repo.get(Market, market_id) do
      nil -> {:error, "Market not found"}
      market -> get_market_tokens(market)
    end
  end

  @doc """
  Finds the market ID for a given token ID.

  Makes a database query to find the market - use `build_mapping/1` for
  batch operations.

  ## Returns

  - `{:ok, market_id}`
  - `:not_found`
  """
  def find_market_by_token(token_id) when is_binary(token_id) do
    # Search in meta->clobTokenIds JSON array
    query = from(m in Market,
      where: fragment("? @> ?", m.meta, ^%{"clobTokenIds" => [token_id]}),
      select: m.id
    )

    case Repo.one(query) do
      nil ->
        # Try with the JSON string format (older data)
        search_pattern = "%\"#{token_id}\"%"
        query2 = from(m in Market,
          where: fragment("?->>'clobTokenIds' LIKE ?", m.meta, ^search_pattern),
          select: m.id
        )
        case Repo.one(query2) do
          nil -> :not_found
          market_id -> {:ok, market_id}
        end

      market_id ->
        {:ok, market_id}
    end
  end

  @doc """
  Returns statistics about the token mapping.
  """
  def stats do
    {:ok, mapping} = build_mapping(include_inactive: true)

    total_tokens = map_size(mapping)
    unique_markets = mapping |> Map.values() |> Enum.map(& &1.market_id) |> Enum.uniq() |> length()

    %{
      total_tokens: total_tokens,
      unique_markets: unique_markets,
      tokens_per_market: if(unique_markets > 0, do: Float.round(total_tokens / unique_markets, 1), else: 0)
    }
  end

  # Private functions

  defp get_outcome_names(%Market{outcomes: %{"options" => options}}) when is_list(options) do
    options
  end

  defp get_outcome_names(%Market{meta: %{"outcomes" => outcomes_json}}) when is_binary(outcomes_json) do
    case Jason.decode(outcomes_json) do
      {:ok, outcomes} when is_list(outcomes) -> outcomes
      _ -> ["Yes", "No"]
    end
  end

  defp get_outcome_names(_), do: ["Yes", "No"]
end
