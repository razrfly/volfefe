defmodule VolfefeMachine.MarketData.AlpacaClient do
  @moduledoc """
  Alpaca market data client for real-time market snapshots.

  **Free tier limitation**: Only provides last 15 minutes of historical data.
  Use AlphaVantageClient for historical baseline calculations.

  Provides functions for:
  - Fetching single bars closest to a timestamp (for snapshots)
  - Fetching asset information (for asset seeding)

  ## Configuration

      # .env
      ALPACA_API_KEY=your_api_key
      ALPACA_API_SECRET=your_api_secret

  ## API Limits (Free Basic Plan)

  - **Historical data**: Last 15 minutes only
  - **Real-time data**: IEX exchange
  - **API calls**: 200/minute
  - **WebSocket**: 30 symbol subscriptions
  """

  @behaviour VolfefeMachine.MarketData.MarketDataProvider

  @base_url "https://data.alpaca.markets/v2/stocks"
  @paper_base_url "https://paper-api.alpaca.markets/v2"

  @doc """
  Get single bar closest to target timestamp.

  Fetches a 2-hour window (1hr before to 1hr after) to find the closest match.
  Used for taking market snapshots.

  **Note**: Free tier only provides last 15 minutes of data.

  ## Parameters

  - `symbol` - Stock symbol (e.g., "SPY")
  - `timestamp` - Target DateTime
  - `timeframe` - Bar timeframe (default: "1Hour")

  ## Returns

  - `{:ok, bar}` - Bar data with open, high, low, close, volume, timestamp
  - `{:error, reason}` - Error message

  ## Examples

      {:ok, bar} = AlpacaClient.get_bar("SPY", ~U[2025-01-15 14:30:00Z])
      bar.close  # => #Decimal<450.25>
  """
  @impl true
  def get_bar(symbol, timestamp, timeframe \\ "1Hour") do
    start_time = DateTime.add(timestamp, -3600, :second) |> DateTime.to_iso8601()
    end_time = DateTime.add(timestamp, 3600, :second) |> DateTime.to_iso8601()

    url = "#{@base_url}/#{symbol}/bars?start=#{start_time}&end=#{end_time}&timeframe=#{timeframe}"

    case make_data_request(url) do
      {:ok, %{"bars" => bars}} when is_list(bars) and length(bars) > 0 ->
        bar = find_closest_bar(bars, timestamp)
        {:ok, parse_bar(bar)}
      _ ->
        {:error, "No data available for this time period"}
    end
  end

  @doc """
  Get historical bars for a date range.

  **Warning**: Free tier only provides last 15 minutes of data.
  For historical baseline calculations, use AlphaVantageClient instead.

  ## Parameters

  - `symbol` - Stock symbol (e.g., "SPY")
  - `start_date` - Start DateTime
  - `end_date` - End DateTime
  - `opts` - Options keyword list
    - `:timeframe` - Bar timeframe (default: "1Hour")
    - `:limit` - Max results (default: 10000)

  ## Returns

  - `{:ok, [bar]}` - List of bars with open, high, low, close, volume, timestamp
  - `{:error, reason}` - Error message

  ## Examples

      # Only works for last 15 minutes on free tier
      start_date = DateTime.utc_now() |> DateTime.add(-900, :second)
      end_date = DateTime.utc_now()
      {:ok, bars} = AlpacaClient.get_bars("SPY", start_date, end_date, timeframe: "1Hour")
  """
  @impl true
  def get_bars(symbol, start_date, end_date, opts \\ []) do
    timeframe = Keyword.get(opts, :timeframe, "1Hour")
    limit = Keyword.get(opts, :limit, 10000)

    start_time = DateTime.to_iso8601(start_date)
    end_time = DateTime.to_iso8601(end_date)

    url = "#{@base_url}/#{symbol}/bars?start=#{start_time}&end=#{end_time}&timeframe=#{timeframe}&limit=#{limit}"

    case make_data_request(url) do
      {:ok, %{"bars" => bars}} when is_list(bars) ->
        {:ok, Enum.map(bars, &parse_bar/1)}
      {:ok, _} ->
        {:error, "No bars found in response"}
      error ->
        error
    end
  end

  @doc """
  Get asset information from Alpaca.

  Used by mix fetch.assets task.

  ## Parameters

  - `symbol` - Stock symbol

  ## Returns

  - `{:ok, asset_data}` - Asset metadata map
  - `{:error, reason}` - Error message
  """
  def get_asset(symbol) do
    url = "#{@paper_base_url}/assets/#{symbol}"

    case make_trading_request(url) do
      {:ok, data} -> {:ok, data}
      error -> error
    end
  end

  @doc """
  List assets from Alpaca (stub - not yet implemented).

  This function is called by MarketData.Loader but is not yet implemented.
  Currently returns an empty list.
  """
  def list_assets(_opts \\ []) do
    # TODO: Implement asset listing when needed
    {:ok, []}
  end

  @doc """
  Get bar for market snapshot with validation.

  Fetches a bar for the specified timestamp with market hours validation
  and returns additional market context for snapshot creation.

  ## Parameters

  - `symbol` - Stock symbol
  - `timestamp` - Target DateTime
  - `opts` - Options
    - `:allow_closed` - Allow fetching when market closed (default: true)
    - `:allow_stale` - Allow data older than 15 min (default: true)

  ## Returns

  - `{:ok, {bar, context}}` - Bar data and market context map
  - `{:error, reason}` - Error message

  ## Context Map

  - `:market_state` - "regular_hours" | "extended_hours" | "closed"
  - `:trading_session_id` - Session identifier (e.g., "2025-01-27-regular")
  - `:data_validity` - "valid" | "stale" | "low_liquidity" | "gap"

  ## Examples

      {:ok, {bar, context}} = AlpacaClient.get_snapshot_bar("SPY", ~U[2025-01-27 14:30:00Z])
      bar.close          # => #Decimal<450.25>
      context.market_state  # => "regular_hours"
  """
  def get_snapshot_bar(symbol, timestamp, opts \\ []) do
    alias VolfefeMachine.MarketData.{Helpers, Snapshot}

    # Validate timing
    allow_closed = Keyword.get(opts, :allow_closed, true)
    allow_stale = Keyword.get(opts, :allow_stale, true)

    case Helpers.validate_snapshot_timing(timestamp, allow_closed: allow_closed, allow_stale: allow_stale) do
      {:ok, market_state} ->
        # Fetch bar
        case get_bar(symbol, timestamp) do
          {:ok, bar} ->
            # Build context
            context = %{
              market_state: market_state,
              trading_session_id: Helpers.generate_session_id(timestamp),
              data_validity: Snapshot.determine_data_validity(
                timestamp,
                market_state,
                bar.volume,
                nil  # avg_volume will be added during snapshot creation
              )
            }

            {:ok, {bar, context}}

          error ->
            error
        end

      {:error, reason} ->
        {:error, reason}
    end
  end

  @doc """
  Get bar with full market context for snapshot creation.

  Enhanced version of get_bar that includes all market validation
  and context needed for creating a market snapshot.

  ## Parameters

  - `symbol` - Stock symbol
  - `timestamp` - Target DateTime
  - `baseline` - BaselineStats struct (optional, for volume context)

  ## Returns

  - `{:ok, snapshot_attrs}` - Map ready for Snapshot.changeset
  - `{:error, reason}` - Error message

  ## Example

      baseline = Repo.get_by(BaselineStats, asset_id: asset.id, window_minutes: 60)
      {:ok, attrs} = AlpacaClient.get_bar_with_context("SPY", timestamp, baseline)

      # attrs contains:
      # - All OHLCV fields (open_price, high_price, etc.)
      # - market_state, data_validity, trading_session_id
      # - volume_vs_avg (if baseline provided)
  """
  def get_bar_with_context(symbol, timestamp, baseline \\ nil) do
    alias VolfefeMachine.MarketData.{Helpers, Snapshot}

    case get_snapshot_bar(symbol, timestamp, allow_closed: true, allow_stale: true) do
      {:ok, {bar, context}} ->
        # Calculate volume context if baseline available
        {volume_vs_avg, volume_z_score} =
          if baseline do
            vol_ratio = Helpers.calculate_volume_ratio(bar.volume, baseline.mean_volume)
            vol_z = calculate_volume_z_score(bar.volume, baseline)
            {vol_ratio, vol_z}
          else
            {nil, nil}
          end

        # Build snapshot attributes
        attrs = %{
          snapshot_timestamp: timestamp,
          open_price: bar.open,
          high_price: bar.high,
          low_price: bar.low,
          close_price: bar.close,
          volume: bar.volume,
          volume_vs_avg: volume_vs_avg,
          volume_z_score: volume_z_score,
          market_state: context.market_state,
          data_validity: Snapshot.determine_data_validity(
            timestamp,
            context.market_state,
            bar.volume,
            if(baseline, do: baseline.mean_volume, else: nil)
          ),
          trading_session_id: context.trading_session_id
        }

        {:ok, attrs}

      error ->
        error
    end
  end

  # Private functions

  defp calculate_volume_z_score(_volume, baseline) when is_nil(baseline), do: nil
  defp calculate_volume_z_score(_volume, %{volume_std_dev: std_dev}) when std_dev == 0, do: nil

  defp calculate_volume_z_score(volume, baseline) do
    observed = Decimal.new(volume)
    mean = Decimal.new(baseline.mean_volume)
    std_dev = Decimal.new(baseline.volume_std_dev)

    Decimal.sub(observed, mean)
    |> Decimal.div(std_dev)
  end

  defp make_data_request(url) do
    headers = [
      {"APCA-API-KEY-ID", get_api_key()},
      {"APCA-API-SECRET-KEY", get_api_secret()}
    ]

    case HTTPoison.get(url, headers) do
      {:ok, %HTTPoison.Response{status_code: 200, body: body}} ->
        Jason.decode(body)

      {:ok, %HTTPoison.Response{status_code: 401}} ->
        {:error, "Authentication failed - check API credentials"}

      {:ok, %HTTPoison.Response{status_code: 404}} ->
        {:error, "Asset not found"}

      {:ok, %HTTPoison.Response{status_code: code}} ->
        {:error, "Alpaca API returned #{code}"}

      {:error, %HTTPoison.Error{reason: reason}} ->
        {:error, "HTTP request failed: #{inspect(reason)}"}
    end
  end

  defp make_trading_request(url) do
    headers = [
      {"APCA-API-KEY-ID", get_api_key()},
      {"APCA-API-SECRET-KEY", get_api_secret()}
    ]

    case HTTPoison.get(url, headers) do
      {:ok, %HTTPoison.Response{status_code: 200, body: body}} ->
        Jason.decode(body)

      {:ok, %HTTPoison.Response{status_code: 401}} ->
        {:error, "Authentication failed - check API credentials"}

      {:ok, %HTTPoison.Response{status_code: 404}} ->
        {:error, "Asset not found"}

      {:ok, %HTTPoison.Response{status_code: code}} ->
        {:error, "Alpaca API returned #{code}"}

      {:error, %HTTPoison.Error{reason: reason}} ->
        {:error, "HTTP request failed: #{inspect(reason)}"}
    end
  end

  defp find_closest_bar(bars, target_timestamp) do
    bars
    |> Enum.min_by(fn bar ->
      bar_time = parse_timestamp(bar["t"])
      abs(DateTime.diff(bar_time, target_timestamp))
    end)
  end

  defp parse_bar(bar) do
    %{
      timestamp: parse_timestamp(bar["t"]),
      open: Decimal.new(to_string(bar["o"])),
      high: Decimal.new(to_string(bar["h"])),
      low: Decimal.new(to_string(bar["l"])),
      close: Decimal.new(to_string(bar["c"])),
      volume: bar["v"]
    }
  end

  defp parse_timestamp(iso_string) do
    {:ok, dt, _} = DateTime.from_iso8601(iso_string)
    dt
  end

  defp get_api_key, do: System.get_env("ALPACA_API_KEY")
  defp get_api_secret, do: System.get_env("ALPACA_API_SECRET")
end
