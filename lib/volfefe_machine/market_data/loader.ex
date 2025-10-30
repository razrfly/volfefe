defmodule VolfefeMachine.MarketData.Loader do
  @moduledoc """
  Loads asset data from Alpaca API into the database.

  Fetches assets from Alpaca and stores them in the `assets` table.
  Preserves complete Alpaca response in the `meta` field for debugging
  and future feature extraction.

  ## Examples

      # Load all active US equities
      {:ok, stats} = Loader.load_all_assets()
      # => {:ok, %{success: 9000, errors: 0, total: 9000}}

      # Load only NASDAQ stocks
      {:ok, stats} = Loader.load_all_assets(exchange: "NASDAQ")

      # Load a specific asset
      {:ok, asset} = Loader.load_asset("AAPL")
  """

  require Logger

  alias VolfefeMachine.Repo
  alias VolfefeMachine.MarketData.{AlpacaClient, Asset}

  @doc """
  Loads all assets from Alpaca API into the database.

  Fetches assets based on options and upserts them into the database.
  Existing assets are updated with new data from Alpaca.

  ## Options

  - `:status` - Filter by status. Default: "active"
  - `:asset_class` - Filter by asset class. Default: "us_equity"
  - `:exchange` - Filter by exchange. Default: nil (all exchanges)

  ## Returns

  - `{:ok, stats}` - Success with statistics map
  - `{:error, reason}` - Fetch failed

  ## Statistics Map

  - `:total` - Total assets fetched from Alpaca
  - `:success` - Successfully inserted/updated
  - `:errors` - Failed to insert/update

  ## Examples

      # Load all active US equities
      {:ok, %{success: 9000, errors: 0}} = Loader.load_all_assets()

      # Load only active NASDAQ stocks
      {:ok, stats} = Loader.load_all_assets(exchange: "NASDAQ")
  """
  def load_all_assets(opts \\ []) do
    Logger.info("Starting Alpaca asset load with options: #{inspect(opts)}")

    case AlpacaClient.list_assets(opts) do
      {:ok, assets} ->
        Logger.info("Fetched #{length(assets)} assets from Alpaca, inserting into database...")

        results = Enum.map(assets, &upsert_asset/1)

        stats = %{
          total: length(assets),
          success: Enum.count(results, &match?({:ok, _}, &1)),
          errors: Enum.count(results, &match?({:error, _}, &1))
        }

        log_stats(stats)
        {:ok, stats}

      {:error, reason} ->
        Logger.error("Failed to fetch assets from Alpaca: #{inspect(reason)}")
        {:error, reason}
    end
  end

  @doc """
  Loads a single asset by symbol.

  Fetches the asset from Alpaca and upserts it into the database.

  ## Parameters

  - `symbol` - Ticker symbol (e.g., "AAPL")

  ## Returns

  - `{:ok, asset}` - Asset struct
  - `{:error, reason}` - Fetch or insert failed

  ## Examples

      {:ok, asset} = Loader.load_asset("AAPL")
      # => %Asset{symbol: "AAPL", name: "Apple Inc.", ...}
  """
  def load_asset(symbol) when is_binary(symbol) do
    Logger.info("Loading asset: #{symbol}")

    case AlpacaClient.get_asset(symbol) do
      {:ok, alpaca_data} ->
        upsert_asset(alpaca_data)

      {:error, reason} ->
        Logger.error("Failed to fetch asset #{symbol}: #{inspect(reason)}")
        {:error, reason}
    end
  end

  # Private functions

  defp upsert_asset(alpaca_data) do
    attrs = %{
      symbol: alpaca_data["symbol"],
      name: alpaca_data["name"],
      exchange: alpaca_data["exchange"],
      class: map_asset_class(alpaca_data["class"]),
      status: map_status(alpaca_data["status"]),
      tradable: alpaca_data["tradable"],
      # Source tracking
      data_source: "alpaca",
      alpaca_id: alpaca_data["id"],
      # CRITICAL: Store complete Alpaca response for debugging and future use
      meta: alpaca_data
    }

    %Asset{}
    |> Asset.changeset(attrs)
    |> Repo.insert(
      on_conflict: {:replace_all_except, [:id, :inserted_at]},
      conflict_target: :symbol
    )
    |> case do
      {:ok, asset} ->
        Logger.debug("✓ Upserted asset: #{asset.symbol} (id: #{asset.id})")
        {:ok, asset}

      {:error, changeset} ->
        symbol = get_in(alpaca_data, ["symbol"]) || "unknown"
        Logger.error("✗ Failed to upsert asset #{symbol}: #{inspect(changeset.errors)}")
        {:error, changeset}
    end
  end

  defp map_asset_class("us_equity"), do: :us_equity
  defp map_asset_class("crypto"), do: :crypto
  defp map_asset_class("us_option"), do: :us_option
  defp map_asset_class(_), do: :other

  defp map_status("active"), do: :active
  defp map_status(_), do: :inactive

  defp log_stats(%{total: total, success: success, errors: errors}) do
    rate = if total > 0, do: Float.round(success / total * 100, 1), else: 0.0

    Logger.info("""
    Asset load complete:
      Total:   #{total}
      Success: #{success}
      Errors:  #{errors}
      Rate:    #{rate}%
    """)
  end
end
