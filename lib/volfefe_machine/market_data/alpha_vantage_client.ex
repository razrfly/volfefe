defmodule VolfefeMachine.MarketData.AlphaVantageClient do
  @moduledoc """
  Alpha Vantage market data client for historical baseline calculations.

  Provides access to 20+ years of historical intraday data (60min intervals).
  Free tier: 500 API calls/day (more than sufficient for baseline calculations).

  ## Usage

      # Get 60 days of hourly data
      {:ok, bars} = AlphaVantageClient.get_bars("SPY", ~U[2025-08-01 00:00:00Z], ~U[2025-10-27 00:00:00Z])

  ## Configuration

      # .env
      ALPHA_VANTAGE_API_KEY=your_api_key

  ## API Limits

  - **Free tier**: 500 API calls/day
  - **Historical data**: 20+ years available
  - **Monthly data**: ~357 bars (28 days) per request
  - **For 60 days**: Need 3 API calls per symbol (3 months)

  ## Data Source

  - Provider: Alpha Vantage (https://www.alphavantage.co/)
  - Endpoint: TIME_SERIES_INTRADAY
  - Format: JSON with OHLCV data
  - Timezone: US/Eastern
  """

  @behaviour VolfefeMachine.MarketData.MarketDataProvider

  @base_url "https://www.alphavantage.co/query"

  @impl true
  def get_bars(symbol, start_date, end_date, opts \\ []) do
    timeframe = Keyword.get(opts, :timeframe, "1Hour")

    # Alpha Vantage only supports 60min for intraday
    interval = case timeframe do
      "1Hour" -> "60min"
      "60min" -> "60min"
      _ -> "60min"  # Default to hourly
    end

    # Determine which months to fetch
    months = get_months_to_fetch(start_date, end_date)

    # Fetch data for each month and combine
    bars = months
    |> Enum.map(fn month -> fetch_month_data(symbol, month, interval) end)
    |> Enum.filter(fn result -> match?({:ok, _}, result) end)
    |> Enum.flat_map(fn {:ok, bars} -> bars end)
    |> Enum.filter(fn bar ->
      DateTime.compare(bar.timestamp, start_date) in [:gt, :eq] and
      DateTime.compare(bar.timestamp, end_date) in [:lt, :eq]
    end)
    |> Enum.sort_by(& &1.timestamp, DateTime)

    if length(bars) > 0 do
      {:ok, bars}
    else
      {:error, "No data available for the specified date range"}
    end
  end

  @impl true
  def get_bar(symbol, timestamp, _timeframe \\ "1Hour") do
    # Fetch bars for the month containing the timestamp
    # Note: Alpha Vantage only supports 60min for intraday, timeframe is ignored
    month = Calendar.strftime(timestamp, "%Y-%m")

    case fetch_month_data(symbol, month, "60min") do
      {:ok, bars} ->
        # Find the bar closest to the target timestamp
        bar = Enum.min_by(bars, fn bar ->
          abs(DateTime.diff(bar.timestamp, timestamp))
        end)
        {:ok, bar}

      error ->
        error
    end
  end

  # Private functions

  defp fetch_month_data(symbol, month, interval) do
    url = "#{@base_url}?function=TIME_SERIES_INTRADAY&symbol=#{symbol}&interval=#{interval}&month=#{month}&outputsize=full&apikey=#{get_api_key()}"

    case HTTPoison.get(url) do
      {:ok, %HTTPoison.Response{status_code: 200, body: body}} ->
        parse_response(body)

      {:ok, %HTTPoison.Response{status_code: code}} ->
        {:error, "Alpha Vantage API returned #{code}"}

      {:error, %HTTPoison.Error{reason: reason}} ->
        {:error, "HTTP request failed: #{inspect(reason)}"}
    end
  end

  defp parse_response(body) do
    case Jason.decode(body) do
      {:ok, %{"Error Message" => error}} ->
        {:error, error}

      {:ok, %{"Note" => note}} ->
        {:error, "API rate limit: #{note}"}

      {:ok, %{"Time Series (60min)" => time_series}} ->
        bars = Enum.map(time_series, fn {timestamp, data} ->
          parse_bar(timestamp, data)
        end)
        {:ok, bars}

      {:ok, _other} ->
        {:error, "Unexpected response format from Alpha Vantage"}

      {:error, reason} ->
        {:error, "JSON parsing failed: #{inspect(reason)}"}
    end
  end

  defp parse_bar(timestamp_str, data) do
    %{
      timestamp: parse_timestamp(timestamp_str),
      open: parse_decimal(data["1. open"]),
      high: parse_decimal(data["2. high"]),
      low: parse_decimal(data["3. low"]),
      close: parse_decimal(data["4. close"]),
      volume: String.to_integer(data["5. volume"])
    }
  end

  defp parse_timestamp(timestamp_str) do
    # Alpha Vantage returns timestamps like "2025-10-27 20:00:00"
    # Parse and convert to UTC DateTime
    case NaiveDateTime.from_iso8601(timestamp_str) do
      {:ok, naive_dt} ->
        # Assume US/Eastern timezone (this is a simplification)
        # For production, might want to use a timezone library
        DateTime.from_naive!(naive_dt, "Etc/UTC")

      {:error, _} ->
        # If parsing fails, it might be missing seconds, try adding them
        case NaiveDateTime.from_iso8601(timestamp_str <> ":00") do
          {:ok, naive_dt} ->
            DateTime.from_naive!(naive_dt, "Etc/UTC")

          {:error, reason} ->
            raise "Failed to parse timestamp '#{timestamp_str}': #{inspect(reason)}"
        end
    end
  end

  defp parse_decimal(str) do
    Decimal.new(str)
  end

  defp get_months_to_fetch(start_date, end_date) do
    # Generate list of YYYY-MM strings for months in range
    current = start_date

    Stream.iterate(current, fn date ->
      date
      |> DateTime.to_date()
      |> Date.beginning_of_month()
      |> Date.add(32)  # Jump to next month
      |> Date.beginning_of_month()
      |> DateTime.new!(Time.new!(0, 0, 0), "Etc/UTC")
    end)
    |> Stream.take_while(fn date ->
      DateTime.compare(date, end_date) in [:lt, :eq]
    end)
    |> Enum.map(fn date ->
      Calendar.strftime(date, "%Y-%m")
    end)
    |> Enum.uniq()
  end

  defp get_api_key do
    System.get_env("ALPHA_VANTAGE_API_KEY") ||
      raise "ALPHA_VANTAGE_API_KEY environment variable not set"
  end
end
