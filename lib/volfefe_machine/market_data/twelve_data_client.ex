defmodule VolfefeMachine.MarketData.TwelveDataClient do
  @moduledoc """
  TwelveData market data client for both historical and real-time market data.

  **Advantages over Alpha Vantage + Alpaca**:
  - Single provider for both historical (60+ days) and real-time data
  - Better rate limits: 800 calls/day vs Alpha Vantage 25/day (32x improvement)
  - More flexible date ranges with start_date/end_date parameters
  - Consistent data format across all time periods

  **Rate Limits (Free Tier)**:
  - **Per minute**: 8 API calls/minute
  - **Daily**: 800 API calls/day
  - **Historical data**: Full history available (20+ years)
  - **Timeframes**: 1min, 5min, 15min, 30min, 1h, 4h, 1day, 1week, 1month

  ## Configuration

      # .env
      TWELVE_DATA_API_KEY=your_api_key

  ## Usage Strategy

  For baseline calculations (6 assets × 60 days):
  - 6 API calls total (1 per asset)
  - Takes ~90 seconds with rate limiting (1 call per 15s to stay safe)
  - Well within daily limit of 800 calls

  For real-time snapshots:
  - 1 API call per snapshot
  - Can handle frequent snapshots throughout the day
  """

  @behaviour VolfefeMachine.MarketData.MarketDataProvider

  @base_url "https://api.twelvedata.com"

  @doc """
  Get historical bars for a date range.

  ## Parameters

  - `symbol` - Stock symbol (e.g., "SPY")
  - `start_date` - Start DateTime
  - `end_date` - End DateTime
  - `opts` - Options keyword list
    - `:timeframe` - Bar timeframe (default: "1Hour")

  ## Returns

  - `{:ok, [bar]}` - List of bars with open, high, low, close, volume, timestamp
  - `{:error, reason}` - Error message

  ## Examples

      start_date = ~U[2025-09-01 00:00:00Z]
      end_date = ~U[2025-10-28 00:00:00Z]
      {:ok, bars} = TwelveDataClient.get_bars("SPY", start_date, end_date, timeframe: "1Hour")
  """
  @impl true
  def get_bars(symbol, start_date, end_date, opts \\ []) do
    timeframe = Keyword.get(opts, :timeframe, "1Hour")
    interval = map_timeframe(timeframe)

    # Format dates as YYYY-MM-DD
    start_str = Calendar.strftime(start_date, "%Y-%m-%d")
    end_str = Calendar.strftime(end_date, "%Y-%m-%d")

    url = "#{@base_url}/time_series?symbol=#{symbol}&interval=#{interval}&start_date=#{start_str}&end_date=#{end_str}&apikey=#{get_api_key()}"

    case Req.get(url, receive_timeout: 30_000) do
      {:ok, %{status: 200, body: body}} ->
        parse_response(body)

      {:ok, %{status: 429, body: body}} ->
        case body do
          %{"message" => message} -> {:error, "Rate limit: #{message}"}
          _ -> {:error, "Rate limit exceeded - wait 60 seconds"}
        end

      {:ok, %{status: 401}} ->
        {:error, "Authentication failed - check TWELVE_DATA_API_KEY"}

      {:ok, %{status: 404}} ->
        {:error, "Symbol not found"}

      {:ok, %{status: code}} ->
        {:error, "TwelveData API returned #{code}"}

      {:error, exception} ->
        {:error, "HTTP request failed: #{inspect(exception)}"}
    end
  end

  @doc """
  Get single bar closest to target timestamp.

  Fetches a 24-hour window around the target timestamp and returns
  the bar closest to the target time.

  ## Parameters

  - `symbol` - Stock symbol (e.g., "SPY")
  - `timestamp` - Target DateTime
  - `timeframe` - Bar timeframe (default: "1Hour")

  ## Returns

  - `{:ok, bar}` - Bar data with open, high, low, close, volume, timestamp
  - `{:error, reason}` - Error message

  ## Examples

      {:ok, bar} = TwelveDataClient.get_bar("SPY", ~U[2025-10-28 14:30:00Z])
      bar.close  # => #Decimal<450.25>
  """
  @impl true
  def get_bar(symbol, timestamp, timeframe \\ "1Hour") do
    # Get bars for 24-hour window around timestamp
    start_date = DateTime.add(timestamp, -43200, :second) # 12 hours before
    end_date = DateTime.add(timestamp, 43200, :second)    # 12 hours after

    case get_bars(symbol, start_date, end_date, timeframe: timeframe) do
      {:ok, [_ | _] = bars} ->
        # Find closest bar to target timestamp
        bar = Enum.min_by(bars, fn bar ->
          abs(DateTime.diff(bar.timestamp, timestamp))
        end)
        {:ok, bar}

      {:ok, []} ->
        {:error, "No data available for this time period"}

      error ->
        error
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
      {:ok, attrs} = TwelveDataClient.get_bar_with_context("SPY", timestamp, baseline)

      # attrs contains:
      # - All OHLCV fields (open_price, high_price, etc.)
      # - market_state, data_validity, trading_session_id
      # - volume_vs_avg (if baseline provided)
  """
  def get_bar_with_context(symbol, timestamp, baseline \\ nil) do
    alias VolfefeMachine.MarketData.{Helpers, Snapshot}

    case get_bar(symbol, timestamp) do
      {:ok, bar} ->
        # Determine market state
        market_state = Snapshot.determine_market_state(timestamp)

        # Calculate volume context if baseline available
        {volume_vs_avg, volume_z_score} =
          with %{mean_volume: mv, volume_std_dev: vsd} <- baseline,
               true <- not is_nil(mv) and not is_nil(vsd) and vsd != 0 do
            {Helpers.calculate_volume_ratio(bar.volume, mv), calculate_volume_z_score(bar.volume, baseline)}
          else
            _ -> {nil, nil}
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
          market_state: market_state,
          data_validity: Snapshot.determine_data_validity(
            timestamp,
            market_state,
            bar.volume,
            if(baseline, do: baseline.mean_volume, else: nil)
          ),
          trading_session_id: Helpers.generate_session_id(timestamp)
        }

        {:ok, attrs}

      error ->
        error
    end
  end

  @doc """
  Check API usage and rate limit status.

  Returns current usage information for monitoring.

  ## Examples

      {:ok, usage} = TwelveDataClient.check_usage()
      usage["current_usage"]  # => 145
      usage["plan_limit"]     # => 800
  """
  def check_usage do
    url = "#{@base_url}/api_usage?apikey=#{get_api_key()}"

    case Req.get(url, receive_timeout: 30_000) do
      {:ok, %{status: 200, body: body}} ->
        {:ok, body}

      {:ok, %{status: code}} ->
        {:error, "API returned #{code}"}

      {:error, exception} ->
        {:error, "HTTP request failed: #{inspect(exception)}"}
    end
  end

  defp calculate_volume_z_score(_volume, baseline) when is_nil(baseline), do: nil
  defp calculate_volume_z_score(_volume, %{volume_std_dev: std_dev}) when std_dev == 0, do: nil

  defp calculate_volume_z_score(volume, baseline) do
    observed = Decimal.new(volume)
    mean = Decimal.new(baseline.mean_volume)
    std_dev = Decimal.new(baseline.volume_std_dev)

    Decimal.sub(observed, mean)
    |> Decimal.div(std_dev)
  end

  # Private functions

  defp parse_response(body) when is_map(body) do
    case body do
      %{"status" => "error", "message" => message} ->
        {:error, message}

      %{"values" => values, "status" => "ok"} ->
        bars = Enum.map(values, &parse_bar/1)
        |> Enum.reverse() # TwelveData returns newest first
        {:ok, bars}

      %{"code" => _code, "message" => message} ->
        {:error, message}

      _other ->
        {:error, "Unexpected response format from TwelveData"}
    end
  end

  defp parse_bar(data) do
    %{
      timestamp: parse_timestamp(data["datetime"]),
      open: Decimal.new(data["open"]),
      high: Decimal.new(data["high"]),
      low: Decimal.new(data["low"]),
      close: Decimal.new(data["close"]),
      volume: parse_volume(data["volume"])
    }
  end

  defp parse_timestamp(datetime_str) do
    # TwelveData returns: "2025-10-28 14:30:00" in UTC
    case NaiveDateTime.from_iso8601(datetime_str) do
      {:ok, naive_dt} ->
        DateTime.from_naive!(naive_dt, "Etc/UTC")

      {:error, _} ->
        # Try adding seconds if missing
        case NaiveDateTime.from_iso8601(datetime_str <> ":00") do
          {:ok, naive_dt} ->
            DateTime.from_naive!(naive_dt, "Etc/UTC")

          {:error, _} ->
            raise "Failed to parse timestamp: #{datetime_str}"
        end
    end
  end

  defp parse_volume(volume) when is_binary(volume) do
    String.to_integer(volume)
  end

  defp parse_volume(volume) when is_integer(volume) do
    volume
  end

  defp map_timeframe(timeframe) do
    case timeframe do
      "1Hour" -> "1h"
      "1Min" -> "1min"
      "5Min" -> "5min"
      "15Min" -> "15min"
      "30Min" -> "30min"
      "1Day" -> "1day"
      other -> other # Pass through if already in TwelveData format
    end
  end

  defp get_api_key do
    System.get_env("TWELVE_DATA_API_KEY") ||
      raise "TWELVE_DATA_API_KEY environment variable not set"
  end
end
