defmodule Mix.Tasks.Fetch.Assets do
  @moduledoc """
  Fetches asset information from Alpaca API and stores in database.

  ## Usage

      # Fetch starter universe
      mix fetch.assets --symbols SPY,QQQ,DIA,IWM,VIX,GLD,TLT

      # Fetch single asset
      mix fetch.assets --symbol AAPL

      # List available assets (no insert)
      mix fetch.assets --list

      # Dry run
      mix fetch.assets --symbols SPY,QQQ --dry-run

  ## Examples

      # Seed the starter universe
      mix fetch.assets --symbols SPY,QQQ,DIA,IWM,VIX,GLD,TLT

      # Check if an asset exists in Alpaca
      mix fetch.assets --symbol TSLA --dry-run
  """

  use Mix.Task
  alias VolfefeMachine.Repo
  alias VolfefeMachine.MarketData.Asset

  @shortdoc "Fetch asset details from Alpaca API and store in database"

  @alpaca_api_base "https://paper-api.alpaca.markets/v2"

  @impl Mix.Task
  def run(args) do
    # Load .env file if it exists
    load_env_file()

    Mix.Task.run("app.start")

    {opts, _, _} = OptionParser.parse(args,
      switches: [symbol: :string, symbols: :string, list: :boolean, dry_run: :boolean],
      aliases: [s: :symbol, d: :dry_run, l: :list]
    )

    cond do
      opts[:list] ->
        list_all_assets()

      opts[:symbols] ->
        symbols = String.split(opts[:symbols], ",") |> Enum.map(&String.trim/1)
        fetch_assets(symbols, opts[:dry_run] || false)

      opts[:symbol] ->
        fetch_assets([opts[:symbol]], opts[:dry_run] || false)

      true ->
        Mix.shell().error("Error: Must specify --symbol or --symbols")
        print_usage()
    end
  end

  defp fetch_assets(symbols, dry_run) do
    Mix.shell().info("\n📡 Fetching #{length(symbols)} assets from Alpaca...\n")

    Enum.each(symbols, fn symbol ->
      case fetch_asset_from_alpaca(symbol) do
        {:ok, asset_data} ->
          if dry_run do
            Mix.shell().info("  [DRY RUN] Would insert: #{symbol} - #{asset_data["name"]}")
          else
            case insert_or_update_asset(asset_data) do
              {:ok, asset} ->
                Mix.shell().info("  ✅ #{symbol}: #{asset.name} (#{asset.exchange})")
              {:error, changeset} ->
                Mix.shell().error("  ❌ #{symbol}: #{inspect(changeset.errors)}")
            end
          end

        {:error, reason} ->
          Mix.shell().error("  ❌ #{symbol}: #{reason}")
      end

      # Rate limiting: 100ms between requests
      Process.sleep(100)
    end)

    unless dry_run do
      count = Repo.aggregate(Asset, :count, :id)
      Mix.shell().info("\n✅ Total assets in database: #{count}\n")
    end
  end

  defp fetch_asset_from_alpaca(symbol) do
    url = "#{@alpaca_api_base}/assets/#{symbol}"
    headers = [
      {"APCA-API-KEY-ID", get_api_key_id()},
      {"APCA-API-SECRET-KEY", get_api_secret()}
    ]

    case HTTPoison.get(url, headers) do
      {:ok, %HTTPoison.Response{status_code: 200, body: body}} ->
        Jason.decode(body)

      {:ok, %HTTPoison.Response{status_code: 404}} ->
        {:error, "Asset not found"}

      {:ok, %HTTPoison.Response{status_code: code}} ->
        {:error, "Alpaca API returned #{code}"}

      {:error, %HTTPoison.Error{reason: reason}} ->
        {:error, inspect(reason)}
    end
  end

  defp insert_or_update_asset(data) do
    attrs = %{
      symbol: data["symbol"],
      name: data["name"],
      exchange: data["exchange"],
      class: parse_asset_class(data["class"]),
      status: parse_status(data["status"]),
      tradable: data["tradable"],
      data_source: "alpaca",
      alpaca_id: data["id"],
      meta: data  # Store complete response
    }

    # Upsert: update if exists, insert if not
    case Repo.get_by(Asset, symbol: data["symbol"]) do
      nil ->
        %Asset{}
        |> Asset.changeset(attrs)
        |> Repo.insert()

      existing ->
        existing
        |> Asset.changeset(attrs)
        |> Repo.update()
    end
  end

  defp parse_asset_class("us_equity"), do: :us_equity
  defp parse_asset_class("crypto"), do: :crypto
  defp parse_asset_class("us_option"), do: :us_option
  defp parse_asset_class(_), do: :other

  defp parse_status("active"), do: :active
  defp parse_status(_), do: :inactive

  defp list_all_assets do
    Mix.shell().info("\n📋 Fetching all available assets from Alpaca...\n")

    url = "#{@alpaca_api_base}/assets?status=active&asset_class=us_equity"
    headers = [
      {"APCA-API-KEY-ID", get_api_key_id()},
      {"APCA-API-SECRET-KEY", get_api_secret()}
    ]

    case HTTPoison.get(url, headers) do
      {:ok, %HTTPoison.Response{status_code: 200, body: body}} ->
        {:ok, assets} = Jason.decode(body)
        Mix.shell().info("Found #{length(assets)} active US equity assets\n")

        assets
        |> Enum.take(20)
        |> Enum.each(fn asset ->
          Mix.shell().info("  #{asset["symbol"]}: #{asset["name"]} (#{asset["exchange"]})")
        end)

        Mix.shell().info("\n... showing first 20 of #{length(assets)}\n")

      {:ok, %HTTPoison.Response{status_code: code}} ->
        Mix.shell().error("Failed to fetch assets: Alpaca API returned #{code}")

      {:error, %HTTPoison.Error{reason: reason}} ->
        Mix.shell().error("Failed to fetch assets: #{inspect(reason)}")
    end
  end

  defp get_api_key_id, do: System.get_env("ALPACA_API_KEY")
  defp get_api_secret, do: System.get_env("ALPACA_API_SECRET")

  # Load environment variables from .env file if it exists
  defp load_env_file do
    env_file = ".env"

    if File.exists?(env_file) do
      env_file
      |> File.read!()
      |> String.split("\n")
      |> Enum.each(fn line ->
        line = String.trim(line)

        # Skip empty lines and comments
        unless line == "" or String.starts_with?(line, "#") do
          case String.split(line, "=", parts: 2) do
            [key, value] ->
              # Remove quotes if present
              value = String.trim(value)
              value = String.trim(value, "\"")
              value = String.trim(value, "'")

              # Set environment variable
              System.put_env(key, value)

            _ ->
              :ok
          end
        end
      end)
    end
  end

  defp print_usage do
    Mix.shell().info("""

    Usage:
      mix fetch.assets --symbols SPY,QQQ,DIA
      mix fetch.assets --symbol AAPL
      mix fetch.assets --list
      mix fetch.assets --symbol SPY --dry-run
    """)
  end
end
