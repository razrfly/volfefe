defmodule Mix.Tasks.Snapshot.Market do
  @moduledoc """
  Captures market snapshots for content with full statistical validation.

  For each content posting, captures 4 snapshots per asset:
  - **before**: 1 hour before posting
  - **1hr_after**: 1 hour after posting
  - **4hr_after**: 4 hours after posting
  - **24hr_after**: 24 hours after posting

  Each snapshot includes:
  - OHLCV data (open, high, low, close, volume)
  - Statistical validation (z-score, significance level)
  - Market context (market state, data validity, trading session)
  - Contamination tracking (isolation score, nearby content)

  ## Usage

      # Capture snapshots for specific content
      mix snapshot.market --content-id 123

      # Dry run (show what would be captured)
      mix snapshot.market --content-id 123 --dry-run

      # Force recapture (overwrite existing)
      mix snapshot.market --content-id 123 --force

  ## Examples

      # Capture all snapshots for content #1
      mix snapshot.market --content-id 1
      # => Creates 24 snapshots (6 assets × 4 windows)

      # Preview what would be captured
      mix snapshot.market --content-id 1 --dry-run
      # => Shows snapshot windows and assets without capturing
  """

  use Mix.Task
  alias VolfefeMachine.{Repo, Content}
  alias VolfefeMachine.MarketData
  alias VolfefeMachine.MarketData.{TwelveDataClient, Snapshot, Helpers}

  @shortdoc "Capture market snapshots for content with statistical validation"

  @impl Mix.Task
  def run(args) do
    # Load .env file
    load_env_file()

    Mix.Task.run("app.start")

    {opts, _, _} = OptionParser.parse(args,
      switches: [content_id: :integer, dry_run: :boolean, force: :boolean],
      aliases: [c: :content_id, d: :dry_run, f: :force]
    )

    content_id = opts[:content_id]

    unless content_id do
      Mix.shell().error("Error: --content-id required")
      print_usage()
      System.halt(1)
    end

    # Load content
    case load_content(content_id) do
      {:ok, content} ->
        if opts[:dry_run] do
          dry_run(content)
        else
          capture_snapshots(content, opts[:force] || false)
        end

      {:error, :not_found} ->
        Mix.shell().error("❌ Content not found: #{content_id}")
        System.halt(1)
    end
  end

  defp capture_snapshots(content, force) do
    Mix.shell().info("\n📸 Capturing market snapshots for content ##{content.id}")
    Mix.shell().info("Published: #{content.published_at}")
    Mix.shell().info("Author: #{content.author}\n")

    # Get active assets
    assets = MarketData.list_active()
    Mix.shell().info("Assets: #{length(assets)} (#{Enum.map_join(assets, ", ", & &1.symbol)})\n")

    # Calculate snapshot windows
    windows = Helpers.calculate_snapshot_windows(content.published_at)

    # Calculate contamination
    {isolation_score, nearby_ids} =
      Helpers.calculate_isolation_score(content.id, content.published_at, 4)

    Mix.shell().info("Isolation Score: #{isolation_score}")
    Mix.shell().info("Nearby Content: #{length(nearby_ids)} messages within ±4hr\n")

    # Capture snapshots for each asset and window
    results = %{
      success: 0,
      skipped: 0,
      failed: 0,
      errors: []
    }

    results =
      Enum.reduce(assets, results, fn asset, acc ->
        Mix.shell().info("[#{asset.symbol}] Capturing snapshots...")

        # Capture "before" baseline first (needed for price change calculations)
        baseline_result = capture_window_snapshot(
          content,
          asset,
          :before,
          windows.before,
          nil,  # No previous snapshot for before
          isolation_score,
          nearby_ids,
          force
        )

        before_snapshot =
          case baseline_result do
            {:ok, snapshot} -> snapshot
            {:skipped, snapshot} -> snapshot
            _ -> nil
          end

        acc = update_results(acc, baseline_result, asset.symbol, "before")

        # Capture after windows (using before snapshot for price change)
        acc =
          [:after_1hr, :after_4hr, :after_24hr]
          |> Enum.reduce(acc, fn window_key, acc ->
            window_type = Helpers.window_key_to_type(window_key)
            timestamp = Map.get(windows, window_key)

            result = capture_window_snapshot(
              content,
              asset,
              window_key,
              timestamp,
              before_snapshot,
              isolation_score,
              nearby_ids,
              force
            )

            update_results(acc, result, asset.symbol, window_type)
          end)

        # Rate limiting between assets
        Process.sleep(100)
        acc
      end)

    print_summary(results, length(assets))
  end

  defp capture_window_snapshot(
    content,
    asset,
    window_key,
    timestamp,
    before_snapshot,
    isolation_score,
    nearby_ids,
    force
  ) do
    window_type = Helpers.window_key_to_type(window_key)
    baseline_window = Helpers.baseline_window_for_snapshot(window_type)

    # Check if snapshot already exists
    existing = get_existing_snapshot(content.id, asset.id, window_type)

    if existing && !force do
      {:skipped, existing}
    else
      # Get baseline statistics
      case Helpers.get_baseline(asset.id, baseline_window) do
        {:ok, baseline} ->
          # Fetch bar with context
          case TwelveDataClient.get_bar_with_context(asset.symbol, timestamp, baseline) do
            {:ok, bar_attrs} ->
              # Calculate price change and z-score
              {price_change_pct, z_score, significance_level} =
                calculate_statistics(bar_attrs, before_snapshot, baseline)

              # Build complete snapshot attributes
              attrs = Map.merge(bar_attrs, %{
                content_id: content.id,
                asset_id: asset.id,
                window_type: window_type,
                price_change_pct: price_change_pct,
                z_score: z_score,
                significance_level: significance_level,
                isolation_score: isolation_score,
                nearby_content_ids: nearby_ids
              })

              # Create or update snapshot
              if existing && force do
                case update_snapshot(existing, attrs) do
                  {:ok, snapshot} ->
                    Mix.shell().info("  🔄 #{window_type}: Updated (z=#{format_z(z_score)}, sig=#{significance_level})")
                    {:ok, snapshot}

                  {:error, changeset} ->
                    {:error, "Failed to update: #{inspect(changeset.errors)}"}
                end
              else
                case create_snapshot(attrs) do
                  {:ok, snapshot} ->
                    Mix.shell().info("  ✅ #{window_type}: Captured (z=#{format_z(z_score)}, sig=#{significance_level})")
                    {:ok, snapshot}

                  {:error, changeset} ->
                    {:error, "Failed to create: #{inspect(changeset.errors)}"}
                end
              end

            {:error, reason} ->
              {:error, "Bar fetch failed: #{reason}"}
          end

        {:error, :not_found} ->
          {:error, "No baseline found for #{baseline_window}min window"}
      end
    end
  end

  defp calculate_statistics(bar_attrs, before_snapshot, baseline) do
    # Calculate price change percentage
    price_change_pct =
      if before_snapshot do
        Helpers.calculate_price_change(before_snapshot.close_price, bar_attrs.close_price)
      else
        Decimal.new("0")  # Before snapshot has no change
      end

    # Calculate z-score
    z_score = Snapshot.calculate_z_score(price_change_pct, baseline)

    # Determine significance level
    significance_level = Snapshot.calculate_significance_level(z_score)

    {price_change_pct, z_score, significance_level}
  end

  defp create_snapshot(attrs) do
    %Snapshot{}
    |> Snapshot.changeset(attrs)
    |> Repo.insert()
  end

  defp update_snapshot(snapshot, attrs) do
    snapshot
    |> Snapshot.changeset(attrs)
    |> Repo.update()
  end

  defp get_existing_snapshot(content_id, asset_id, window_type) do
    Repo.get_by(Snapshot, content_id: content_id, asset_id: asset_id, window_type: window_type)
  end

  defp update_results(results, result, symbol, window_type) do
    case result do
      {:ok, _snapshot} ->
        %{results | success: results.success + 1}

      {:skipped, _snapshot} ->
        Mix.shell().info("  ⏭️  #{window_type}: Skipped (exists, use --force to update)")
        %{results | skipped: results.skipped + 1}

      {:error, reason} ->
        Mix.shell().error("  ❌ #{window_type}: #{reason}")
        %{results |
          failed: results.failed + 1,
          errors: [{symbol, window_type, reason} | results.errors]
        }
    end
  end

  defp dry_run(content) do
    Mix.shell().info("\n🔍 DRY RUN - Would capture snapshots for content ##{content.id}\n")

    # Calculate windows
    windows = Helpers.calculate_snapshot_windows(content.published_at)

    Mix.shell().info("Published: #{content.published_at}")
    Mix.shell().info("Author: #{content.author}\n")

    Mix.shell().info("Snapshot Windows:")
    Mix.shell().info("  before:     #{windows.before}")
    Mix.shell().info("  1hr_after:  #{windows.after_1hr}")
    Mix.shell().info("  4hr_after:  #{windows.after_4hr}")
    Mix.shell().info("  24hr_after: #{windows.after_24hr}\n")

    # Calculate contamination
    {isolation_score, nearby_ids} =
      Helpers.calculate_isolation_score(content.id, content.published_at, 4)

    Mix.shell().info("Contamination Analysis:")
    Mix.shell().info("  Isolation Score: #{isolation_score}")
    Mix.shell().info("  Nearby Content: #{length(nearby_ids)} messages within ±4hr\n")

    # Show assets
    assets = MarketData.list_active()
    Mix.shell().info("Assets (#{length(assets)}):")

    Enum.each(assets, fn asset ->
      Mix.shell().info("  #{asset.symbol}: #{asset.name}")
    end)

    Mix.shell().info("\nWould create #{length(assets) * 4} snapshots (#{length(assets)} assets × 4 windows)")
    Mix.shell().info("\nRun without --dry-run to capture.\n")
  end

  defp print_summary(results, asset_count) do
    Mix.shell().info("\n" <> String.duplicate("=", 60))
    Mix.shell().info("📸 SNAPSHOT CAPTURE SUMMARY")
    Mix.shell().info(String.duplicate("=", 60))
    Mix.shell().info("✅ Success: #{results.success}")
    Mix.shell().info("⏭️  Skipped: #{results.skipped}")
    Mix.shell().info("❌ Failed: #{results.failed}")
    Mix.shell().info("Expected: #{asset_count * 4} total snapshots")

    if length(results.errors) > 0 do
      Mix.shell().info("\nErrors:")
      Enum.each(results.errors, fn {symbol, window, reason} ->
        Mix.shell().error("  #{symbol} #{window}: #{reason}")
      end)
    end

    # Query actual count from database
    total = Repo.aggregate(Snapshot, :count)
    Mix.shell().info("\nTotal snapshots in database: #{total}")
    Mix.shell().info("\n✅ Snapshot capture complete!\n")
  end

  defp load_content(content_id) do
    case Repo.get(Content.Content, content_id) do
      nil -> {:error, :not_found}
      content -> {:ok, content}
    end
  end

  defp format_z(nil), do: "N/A"
  defp format_z(z_score) do
    z_score
    |> Decimal.to_float()
    |> Float.round(2)
    |> Float.to_string()
  end

  defp print_usage do
    Mix.shell().info("""

    Usage:
      mix snapshot.market --content-id <id>
      mix snapshot.market --content-id 1 --dry-run
      mix snapshot.market --content-id 1 --force
    """)
  end

  # Load environment variables from .env file
  defp load_env_file do
    env_file = ".env"

    if File.exists?(env_file) do
      env_file
      |> File.read!()
      |> String.split("\n")
      |> Enum.each(fn line ->
        line = String.trim(line)

        unless line == "" or String.starts_with?(line, "#") do
          case String.split(line, "=", parts: 2) do
            [key, value] ->
              value = String.trim(value)
              value = String.trim(value, "\"")
              value = String.trim(value, "'")
              System.put_env(key, value)

            _ ->
              :ok
          end
        end
      end)
    end
  end
end
