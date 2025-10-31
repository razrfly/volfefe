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

  **NOTE**: This function is not yet implemented as `AlpacaClient.list_assets/1`
  is a stub. Use `load_asset/1` for individual assets instead.

  ## Options

  - `:status` - Filter by status. Default: "active"
  - `:asset_class` - Filter by asset class. Default: "us_equity"
  - `:exchange` - Filter by exchange. Default: nil (all exchanges)

  ## Returns

  - `{:error, :not_implemented}` - Function not yet implemented

  ## Examples

      # This will return an error
      {:error, :not_implemented} = Loader.load_all_assets()

      # Use load_asset/1 instead
      {:ok, asset} = Loader.load_asset("AAPL")
  """
  def load_all_assets(_opts \\ []) do
    Logger.warning("load_all_assets is not yet implemented - use load_asset/1 for individual assets")
    {:error, :not_implemented}
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
end
