defmodule VolfefeMachine.MarketData.Helpers do
  @moduledoc """
  Helper functions for market data analysis and validation.

  Provides utilities for:
  - Market hours detection and validation
  - Contamination detection (nearby content)
  - Statistical calculations (z-scores, significance)
  - Time window calculations
  """

  import Ecto.Query
  alias VolfefeMachine.{Repo, Content}
  alias VolfefeMachine.MarketData.{Snapshot, BaselineStats}

  @doc """
  Determines if a timestamp falls within regular trading hours.

  Regular hours: Monday-Friday, 9:30 AM - 4:00 PM Eastern Time

  ## Parameters

  - `timestamp` - DateTime in UTC

  ## Returns

  - Boolean: true if in regular hours

  ## Examples

      iex> Helpers.regular_hours?(~U[2025-01-27 14:30:00Z])  # 9:30 AM ET
      true

      iex> Helpers.regular_hours?(~U[2025-01-27 21:00:00Z])  # 4:00 PM ET (closed)
      false

      iex> Helpers.regular_hours?(~U[2025-01-26 14:30:00Z])  # Sunday
      false
  """
  def regular_hours?(timestamp) do
    Snapshot.determine_market_state(timestamp) == "regular_hours"
  end

  @doc """
  Determines if a timestamp falls within extended trading hours.

  Extended hours: Monday-Friday, 4:00-9:30 AM or 4:00-8:00 PM Eastern Time

  ## Parameters

  - `timestamp` - DateTime in UTC

  ## Returns

  - Boolean: true if in extended hours
  """
  def extended_hours?(timestamp) do
    Snapshot.determine_market_state(timestamp) == "extended_hours"
  end

  @doc """
  Determines if market is closed at given timestamp.

  Market closed: Weekends or outside 4:00 AM - 8:00 PM ET

  ## Parameters

  - `timestamp` - DateTime in UTC

  ## Returns

  - Boolean: true if market closed
  """
  def market_closed?(timestamp) do
    Snapshot.determine_market_state(timestamp) == "closed"
  end

  @doc """
  Finds content posted within a time window around a target timestamp.

  Used for contamination detection to identify potentially confounding events.

  ## Parameters

  - `target_timestamp` - Center point for window
  - `window_hours` - Hours before and after (default: 4)
  - `exclude_content_id` - Optional content ID to exclude (e.g., the target content)

  ## Returns

  - List of Content structs within the window

  ## Examples

      # Find all content within ±4 hours of target
      nearby = Helpers.find_nearby_content(~U[2025-01-27 14:30:00Z])

      # Exclude the target content itself
      nearby = Helpers.find_nearby_content(target_time, 4, exclude_content_id: 123)
  """
  def find_nearby_content(target_timestamp, window_hours \\ 4, opts \\ []) do
    exclude_id = Keyword.get(opts, :exclude_content_id)

    start_time = DateTime.add(target_timestamp, -window_hours * 3600, :second)
    end_time = DateTime.add(target_timestamp, window_hours * 3600, :second)

    query =
      from c in Content.Content,
        where: c.published_at >= ^start_time and c.published_at <= ^end_time

    query =
      if exclude_id do
        from c in query, where: c.id != ^exclude_id
      else
        query
      end

    Repo.all(query)
  end

  @doc """
  Calculates isolation score for a content posting.

  Isolation score indicates how contaminated the measurement window is:
  - 1.0 = Perfectly isolated (no nearby content)
  - 0.5 = Moderate contamination (some nearby content)
  - 0.0 = Heavily contaminated (many nearby messages)

  ## Algorithm

  - 0 nearby messages: score = 1.0 (perfect isolation)
  - 1 nearby message: score = 0.7 (good isolation)
  - 2 nearby messages: score = 0.5 (moderate contamination)
  - 3+ nearby messages: score = 0.3 (high contamination)
  - 5+ nearby messages: score = 0.0 (severe contamination)

  ## Parameters

  - `content_id` - Target content ID
  - `published_at` - When content was published
  - `window_hours` - Hours before/after to check (default: 4)

  ## Returns

  - `{isolation_score, nearby_content_ids}` tuple

  ## Examples

      {score, nearby_ids} = Helpers.calculate_isolation_score(123, ~U[2025-01-27 14:30:00Z])
      # => {Decimal.new("1.0"), []}  # Perfect isolation

      {score, nearby_ids} = Helpers.calculate_isolation_score(456, ~U[2025-01-27 15:00:00Z])
      # => {Decimal.new("0.5"), [123, 789]}  # 2 nearby messages
  """
  def calculate_isolation_score(content_id, published_at, window_hours \\ 4) do
    nearby_content =
      find_nearby_content(published_at, window_hours, exclude_content_id: content_id)

    nearby_ids = Enum.map(nearby_content, & &1.id)
    count = length(nearby_ids)

    score =
      cond do
        count == 0 -> Decimal.new("1.0")
        count == 1 -> Decimal.new("0.7")
        count == 2 -> Decimal.new("0.5")
        count == 3 -> Decimal.new("0.3")
        count == 4 -> Decimal.new("0.1")
        true -> Decimal.new("0.0")
      end

    {score, nearby_ids}
  end

  @doc """
  Calculates time windows for market snapshots relative to content posting.

  Returns map with timestamps for each snapshot window:
  - `:before` - 1 hour before posting
  - `:after_1hr` - 1 hour after posting
  - `:after_4hr` - 4 hours after posting
  - `:after_24hr` - 24 hours after posting

  ## Parameters

  - `published_at` - Content publication timestamp

  ## Returns

  - Map with window timestamps

  ## Examples

      windows = Helpers.calculate_snapshot_windows(~U[2025-01-27 14:30:00Z])
      # => %{
      #   before: ~U[2025-01-27 13:30:00Z],
      #   after_1hr: ~U[2025-01-27 15:30:00Z],
      #   after_4hr: ~U[2025-01-27 18:30:00Z],
      #   after_24hr: ~U[2025-01-28 14:30:00Z]
      # }
  """
  def calculate_snapshot_windows(published_at) do
    %{
      before: DateTime.add(published_at, -3600, :second),
      after_1hr: DateTime.add(published_at, 3600, :second),
      after_4hr: DateTime.add(published_at, 4 * 3600, :second),
      after_24hr: DateTime.add(published_at, 24 * 3600, :second)
    }
  end

  @doc """
  Maps window timestamp keys to database window_type values.

  ## Examples

      iex> Helpers.window_key_to_type(:before)
      "before"

      iex> Helpers.window_key_to_type(:after_1hr)
      "1hr_after"
  """
  def window_key_to_type(:before), do: "before"
  def window_key_to_type(:after_1hr), do: "1hr_after"
  def window_key_to_type(:after_4hr), do: "4hr_after"
  def window_key_to_type(:after_24hr), do: "24hr_after"

  @doc """
  Determines which baseline window to use for a given snapshot window.

  Maps snapshot windows to appropriate baseline window sizes:
  - `before` → 60 minutes (1hr baseline)
  - `1hr_after` → 60 minutes (1hr baseline)
  - `4hr_after` → 240 minutes (4hr baseline)
  - `24hr_after` → 1440 minutes (24hr baseline)

  ## Parameters

  - `window_type` - Snapshot window type

  ## Returns

  - Integer: baseline window in minutes

  ## Examples

      iex> Helpers.baseline_window_for_snapshot("1hr_after")
      60

      iex> Helpers.baseline_window_for_snapshot("24hr_after")
      1440
  """
  def baseline_window_for_snapshot("before"), do: 60
  def baseline_window_for_snapshot("1hr_after"), do: 60
  def baseline_window_for_snapshot("4hr_after"), do: 240
  def baseline_window_for_snapshot("24hr_after"), do: 1440

  @doc """
  Gets baseline statistics for an asset and window.

  ## Parameters

  - `asset_id` - Asset ID
  - `window_minutes` - Window size in minutes (60, 240, or 1440)

  ## Returns

  - `{:ok, baseline}` - BaselineStats struct
  - `{:error, :not_found}` - No baseline found

  ## Examples

      {:ok, baseline} = Helpers.get_baseline(spy_id, 60)
      baseline.mean_return  # => 0.0085
      baseline.std_dev      # => 0.2045
  """
  def get_baseline(asset_id, window_minutes) do
    case Repo.get_by(BaselineStats, asset_id: asset_id, window_minutes: window_minutes) do
      nil -> {:error, :not_found}
      baseline -> {:ok, baseline}
    end
  end

  @doc """
  Calculates price change percentage between two prices.

  ## Parameters

  - `start_price` - Starting price (Decimal)
  - `end_price` - Ending price (Decimal)

  ## Returns

  - Decimal percentage change

  ## Examples

      iex> Helpers.calculate_price_change(Decimal.new("100"), Decimal.new("101"))
      Decimal.new("1.0")  # +1.0%

      iex> Helpers.calculate_price_change(Decimal.new("100"), Decimal.new("99"))
      Decimal.new("-1.0")  # -1.0%
  """
  def calculate_price_change(start_price, end_price) do
    Decimal.sub(end_price, start_price)
    |> Decimal.div(start_price)
    |> Decimal.mult(Decimal.new("100"))
  end

  @doc """
  Calculates volume ratio vs. average.

  ## Parameters

  - `current_volume` - Current bar volume
  - `avg_volume` - Average historical volume

  ## Returns

  - Decimal ratio (e.g., 1.2 = 20% above average)

  ## Examples

      iex> Helpers.calculate_volume_ratio(12_000_000, 10_000_000)
      Decimal.new("1.2")  # 20% above average
  """
  def calculate_volume_ratio(_current_volume, avg_volume) when avg_volume == 0, do: Decimal.new("0")

  def calculate_volume_ratio(current_volume, avg_volume) do
    Decimal.div(Decimal.new(current_volume), Decimal.new(avg_volume))
  end

  @doc """
  Generates trading session ID for a timestamp.

  Format: "YYYY-MM-DD-{regular|extended|closed}"

  ## Parameters

  - `timestamp` - DateTime in UTC

  ## Returns

  - String session ID

  ## Examples

      iex> Helpers.generate_session_id(~U[2025-01-27 14:30:00Z])
      "2025-01-27-regular"
  """
  def generate_session_id(timestamp) do
    date = Date.to_string(DateTime.to_date(timestamp))
    state = Snapshot.determine_market_state(timestamp)

    state_suffix =
      case state do
        "regular_hours" -> "regular"
        "extended_hours" -> "extended"
        "closed" -> "closed"
      end

    "#{date}-#{state_suffix}"
  end

  @doc """
  Validates that a snapshot can be taken at the given timestamp.

  Checks:
  - Data is not too stale (within 15 minutes of now for real-time)
  - Market state is appropriate for data collection

  ## Parameters

  - `timestamp` - When snapshot would be taken
  - `opts` - Options
    - `:allow_stale` - Allow data older than 15 min (default: false)
    - `:allow_closed` - Allow snapshots when market closed (default: false)

  ## Returns

  - `{:ok, market_state}` - Valid snapshot
  - `{:error, reason}` - Cannot take snapshot

  ## Examples

      {:ok, "regular_hours"} = Helpers.validate_snapshot_timing(~U[2025-01-27 14:30:00Z])
      {:error, :market_closed} = Helpers.validate_snapshot_timing(~U[2025-01-26 14:30:00Z])  # Sunday
  """
  def validate_snapshot_timing(timestamp, opts \\ []) do
    allow_stale = Keyword.get(opts, :allow_stale, false)
    allow_closed = Keyword.get(opts, :allow_closed, false)

    market_state = Snapshot.determine_market_state(timestamp)
    now = DateTime.utc_now()
    age_minutes = DateTime.diff(now, timestamp, :minute)

    cond do
      market_state == "closed" and not allow_closed ->
        {:error, :market_closed}

      age_minutes > 15 and not allow_stale ->
        {:error, :stale_data}

      true ->
        {:ok, market_state}
    end
  end
end
