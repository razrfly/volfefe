defmodule VolfefeMachine.Polymarket.FormatHelpers do
  @moduledoc """
  Shared formatting helpers for Polymarket modules.

  Provides consistent formatting for:
  - Relative time display
  - Decimal/number formatting
  - Wallet address truncation
  - Date/time formatting
  - CSV escaping
  """

  # ============================================
  # Time Formatting
  # ============================================

  @doc """
  Format a datetime as relative time (e.g., "5m ago", "2h ago").

  ## Examples

      iex> relative_time(DateTime.utc_now())
      "0s ago"

      iex> relative_time(nil)
      "N/A"
  """
  def relative_time(nil), do: "N/A"

  def relative_time(%DateTime{} = dt) do
    seconds = DateTime.diff(DateTime.utc_now(), dt)
    format_relative_seconds(seconds)
  end

  def relative_time(%NaiveDateTime{} = dt) do
    {:ok, datetime} = DateTime.from_naive(dt, "Etc/UTC")
    relative_time(datetime)
  end

  defp format_relative_seconds(seconds) when seconds < 0, do: "just now"
  defp format_relative_seconds(seconds) when seconds < 60, do: "#{seconds}s ago"
  defp format_relative_seconds(seconds) when seconds < 3600, do: "#{div(seconds, 60)}m ago"
  defp format_relative_seconds(seconds) when seconds < 86400, do: "#{div(seconds, 3600)}h ago"
  defp format_relative_seconds(seconds), do: "#{div(seconds, 86400)}d ago"

  @doc """
  Format a datetime as standard string.

  ## Examples

      iex> format_datetime(~U[2024-01-15 10:30:00Z])
      "2024-01-15 10:30"
  """
  def format_datetime(nil), do: "N/A"

  def format_datetime(%DateTime{} = dt) do
    Calendar.strftime(dt, "%Y-%m-%d %H:%M")
  end

  def format_datetime(%NaiveDateTime{} = dt) do
    Calendar.strftime(dt, "%Y-%m-%d %H:%M")
  end

  # ============================================
  # Number Formatting
  # ============================================

  @doc """
  Format a decimal with configurable precision (default: 2).

  ## Examples

      iex> format_decimal(Decimal.new("1.2345"))
      "1.23"

      iex> format_decimal(nil)
      "N/A"
  """
  def format_decimal(value, precision \\ 2)

  def format_decimal(nil, _precision), do: "N/A"

  def format_decimal(%Decimal{} = d, precision) do
    Decimal.round(d, precision) |> Decimal.to_string()
  end

  def format_decimal(f, precision) when is_float(f) do
    Float.round(f, precision) |> Float.to_string()
  end

  def format_decimal(n, _precision), do: "#{n}"

  @doc """
  Format a number as a probability percentage.

  ## Examples

      iex> format_probability(Decimal.new("0.75"))
      "75.0%"

      iex> format_probability(0.5)
      "50.0%"
  """
  def format_probability(nil), do: "N/A"

  def format_probability(%Decimal{} = d) do
    "#{Decimal.round(Decimal.mult(d, 100), 1)}%"
  end

  def format_probability(f) when is_float(f) do
    "#{Float.round(f * 100, 1)}%"
  end

  def format_probability(n), do: "#{n}%"

  @doc """
  Format a number as money (USD).

  ## Examples

      iex> format_money(Decimal.new("1234.56"))
      "$1234.56"
  """
  def format_money(nil), do: "N/A"
  def format_money(%Decimal{} = d), do: "$#{Decimal.round(d, 2) |> Decimal.to_string()}"
  def format_money(n), do: "$#{n}"

  # ============================================
  # String Formatting
  # ============================================

  @doc """
  Truncate a wallet address to short form.

  ## Examples

      iex> format_wallet("0x1234567890abcdef1234567890abcdef12345678")
      "0x1234...5678"
  """
  def format_wallet(nil), do: "Unknown"

  def format_wallet(address) when byte_size(address) > 10 do
    "#{String.slice(address, 0, 6)}...#{String.slice(address, -4, 4)}"
  end

  def format_wallet(address), do: address

  @doc """
  Truncate a string to max length with ellipsis.

  ## Examples

      iex> truncate("Hello World", 8)
      "Hello..."
  """
  def truncate(nil, _), do: ""

  def truncate(str, max_length) when is_binary(str) do
    if String.length(str) > max_length do
      String.slice(str, 0, max_length) <> "..."
    else
      str
    end
  end

  # ============================================
  # CSV Helpers
  # ============================================

  @doc """
  Escape a value for CSV output per RFC 4180.

  Handles:
  - Quotes are doubled
  - Values containing commas, quotes, or newlines are quoted

  ## Examples

      iex> csv_escape("hello")
      "hello"

      iex> csv_escape("hello, world")
      ~s("hello, world")

      iex> csv_escape(~s(say "hi"))
      ~s("say ""hi""")
  """
  def csv_escape(nil), do: ""
  def csv_escape(value) when not is_binary(value), do: csv_escape("#{value}")

  def csv_escape(value) when is_binary(value) do
    needs_quoting = String.contains?(value, [",", "\"", "\n", "\r"])

    if needs_quoting do
      escaped = String.replace(value, "\"", "\"\"")
      "\"#{escaped}\""
    else
      value
    end
  end

  @doc """
  Generate a CSV row from a list of values, properly escaped.

  ## Examples

      iex> csv_row(["id", "name", "value"])
      "id,name,value"

      iex> csv_row([1, "hello, world", 3.14])
      ~s(1,"hello, world",3.14)
  """
  def csv_row(values) when is_list(values) do
    values
    |> Enum.map(&csv_escape/1)
    |> Enum.join(",")
  end
end
