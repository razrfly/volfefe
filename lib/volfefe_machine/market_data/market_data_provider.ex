defmodule VolfefeMachine.MarketData.MarketDataProvider do
  @moduledoc """
  Behavior defining the interface for market data providers.

  Allows switching between different data sources (Alpaca, Alpha Vantage, etc.)
  without changing application logic.

  ## Implementations

  - `AlphaVantageClient` - For historical baseline calculations (60+ days)
  - `AlpacaClient` - For real-time market snapshots (15 min limit on free tier)

  ## Configuration

      # config/config.exs
      config :volfefe_machine, :market_data_provider,
        historical: VolfefeMachine.MarketData.AlphaVantageClient,
        realtime: VolfefeMachine.MarketData.AlpacaClient
  """

  @doc """
  Fetches historical bars for a date range.

  ## Parameters

  - `symbol` - Stock symbol (e.g., "SPY")
  - `start_date` - Start DateTime
  - `end_date` - End DateTime
  - `opts` - Options keyword list
    - `:timeframe` - Bar timeframe (default: "1Hour")
    - `:limit` - Max results (provider-specific)

  ## Returns

  - `{:ok, [bar]}` - List of bars with timestamp, open, high, low, close, volume
  - `{:error, reason}` - Error message

  ## Example Bar Structure

      %{
        timestamp: ~U[2025-10-27 14:00:00Z],
        open: Decimal.new("685.24"),
        high: Decimal.new("685.24"),
        low: Decimal.new("685.24"),
        close: Decimal.new("685.24"),
        volume: 1303163
      }
  """
  @callback get_bars(symbol :: String.t(), start_date :: DateTime.t(), end_date :: DateTime.t(), opts :: Keyword.t()) ::
    {:ok, [map()]} | {:error, String.t()}

  @doc """
  Fetches a single bar closest to the target timestamp.

  Used for taking market snapshots at specific points in time.

  ## Parameters

  - `symbol` - Stock symbol
  - `timestamp` - Target DateTime
  - `timeframe` - Bar timeframe (default: "1Hour")

  ## Returns

  - `{:ok, bar}` - Bar data closest to timestamp
  - `{:error, reason}` - Error message
  """
  @callback get_bar(symbol :: String.t(), timestamp :: DateTime.t(), timeframe :: String.t()) ::
    {:ok, map()} | {:error, String.t()}
end
