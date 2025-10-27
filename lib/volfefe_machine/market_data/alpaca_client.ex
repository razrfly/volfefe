defmodule VolfefeMachine.MarketData.AlpacaClient do
  @moduledoc """
  HTTP client for Alpaca Markets Trading API.

  Fetches asset data from Alpaca's `/v2/assets` endpoint.
  Supports paper trading and live trading environments.

  ## Configuration

  Requires environment variables:
  - `ALPACA_API_KEY` - Your Alpaca API key
  - `ALPACA_SECRET_KEY` - Your Alpaca secret key

  ## Examples

      # List all active US equities
      {:ok, assets} = AlpacaClient.list_assets()

      # List only NASDAQ stocks
      {:ok, assets} = AlpacaClient.list_assets(exchange: "NASDAQ")

      # Get a specific asset
      {:ok, asset} = AlpacaClient.get_asset("AAPL")
  """

  require Logger

  @base_url "https://paper-api.alpaca.markets"

  @doc """
  Creates a new Req client configured for Alpaca API.

  Reads credentials from environment variables and sets up
  authentication headers.

  ## Raises

  Raises if `ALPACA_API_KEY` or `ALPACA_SECRET_KEY` are not set.
  """
  def new do
    api_key = System.get_env("ALPACA_API_KEY") || raise "ALPACA_API_KEY not set"
    secret_key = System.get_env("ALPACA_SECRET_KEY") || raise "ALPACA_SECRET_KEY not set"

    Req.new(
      base_url: @base_url,
      headers: [
        {"APCA-API-KEY-ID", api_key},
        {"APCA-API-SECRET-KEY", secret_key}
      ],
      retry: :transient,
      max_retries: 3,
      retry_delay: fn attempt -> :timer.seconds(attempt) end
    )
  end

  @doc """
  Lists assets from Alpaca API.

  ## Options

  - `:status` - Filter by status ("active", "inactive"). Default: "active"
  - `:asset_class` - Filter by asset class ("us_equity", "crypto"). Default: "us_equity"
  - `:exchange` - Filter by exchange ("NASDAQ", "NYSE", etc.). Default: nil

  ## Returns

  - `{:ok, assets}` - List of asset maps
  - `{:error, reason}` - Error tuple

  ## Examples

      # Get all active US equities
      {:ok, assets} = AlpacaClient.list_assets()

      # Get only NASDAQ stocks
      {:ok, assets} = AlpacaClient.list_assets(exchange: "NASDAQ")

      # Get crypto assets
      {:ok, assets} = AlpacaClient.list_assets(asset_class: "crypto")
  """
  def list_assets(opts \\ []) do
    client = new()

    params =
      [
        status: Keyword.get(opts, :status, "active"),
        asset_class: Keyword.get(opts, :asset_class, "us_equity")
      ]
      |> maybe_add_exchange(opts)

    Logger.info("Fetching assets from Alpaca API with params: #{inspect(params)}")

    case Req.get(client, url: "/v2/assets", params: params) do
      {:ok, %{status: 200, body: assets}} when is_list(assets) ->
        Logger.info("Successfully fetched #{length(assets)} assets from Alpaca")
        {:ok, assets}

      {:ok, %{status: status, body: body}} ->
        Logger.error("Alpaca API error: status=#{status}, body=#{inspect(body)}")
        {:error, {:api_error, status, body}}

      {:error, reason} ->
        Logger.error("Failed to fetch from Alpaca: #{inspect(reason)}")
        {:error, reason}
    end
  end

  @doc """
  Gets a single asset by symbol.

  ## Parameters

  - `symbol` - The ticker symbol (e.g., "AAPL")

  ## Returns

  - `{:ok, asset}` - Asset map
  - `{:error, :not_found}` - Asset not found
  - `{:error, reason}` - Other errors

  ## Examples

      {:ok, asset} = AlpacaClient.get_asset("AAPL")
      # => %{"symbol" => "AAPL", "name" => "Apple Inc.", ...}
  """
  def get_asset(symbol) when is_binary(symbol) do
    client = new()

    Logger.debug("Fetching asset: #{symbol}")

    case Req.get(client, url: "/v2/assets/#{symbol}") do
      {:ok, %{status: 200, body: asset}} ->
        {:ok, asset}

      {:ok, %{status: 404}} ->
        Logger.debug("Asset not found: #{symbol}")
        {:error, :not_found}

      {:ok, %{status: status, body: body}} ->
        Logger.error("Alpaca API error for #{symbol}: status=#{status}, body=#{inspect(body)}")
        {:error, {:api_error, status, body}}

      {:error, reason} ->
        Logger.error("Failed to fetch asset #{symbol}: #{inspect(reason)}")
        {:error, reason}
    end
  end

  # Private helpers

  defp maybe_add_exchange(params, opts) do
    case Keyword.get(opts, :exchange) do
      nil -> params
      exchange -> Keyword.put(params, :exchange, exchange)
    end
  end
end
