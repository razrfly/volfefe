defmodule Mix.Tasks.Ingest.Content do
  @moduledoc """
  Smart social media content import with incremental and gap-fill modes.

  ## Usage

      # Check import status and get recommendations
      mix ingest.content --status --source truth_social --username realDonaldTrump

      # Import only new posts (incremental)
      mix ingest.content --source truth_social --username realDonaldTrump --mode newest

      # Fill gaps in specific date range
      mix ingest.content --source truth_social --username realDonaldTrump --mode backfill --date-range "2025-10-01 2025-10-31"

      # Full import with custom limit
      mix ingest.content --source truth_social --username realDonaldTrump --mode full --limit 1000

      # Dry run to preview
      mix ingest.content --source truth_social --username realDonaldTrump --mode newest --dry-run

  ## Modes

    * `newest` (default) - Import only posts published after most recent post in database
    * `backfill` - Fill gaps in historical data for specified date range
    * `full` - Complete import with custom limit and batch processing

  ## Options

    * `--source, -s` - Content source (currently: truth_social)
    * `--username, -u` - Username/profile to fetch
    * `--mode, -m` - Import mode: newest, backfill, full (default: newest)
    * `--limit, -l` - Max posts to fetch (auto-calculated for 'newest', default 100 for 'full')
    * `--date-range` - Date range for backfill mode: "YYYY-MM-DD YYYY-MM-DD"
    * `--status` - Show import status and recommendations without importing
    * `--include-replies` - Include replies in results
    * `--dry-run, -d` - Preview without importing
    * `--force, -f` - [Reserved] Force re-classification of already classified posts (not yet implemented)

  ## Examples

      # Daily incremental import
      mix ingest.content -s truth_social -u realDonaldTrump --mode newest

      # Check status first
      mix ingest.content --status -s truth_social -u realDonaldTrump

      # Fill historical gap
      mix ingest.content -s truth_social -u realDonaldTrump --mode backfill --date-range "2024-03-15 2024-03-22"

      # Large import
      mix ingest.content -s truth_social -u realDonaldTrump --mode full --limit 1000
  """

  use Mix.Task

  alias VolfefeMachine.Ingestion.{ApifyClient, Importer, ImportAnalyzer}

  require Logger

  @shortdoc "Smart social media content import with multiple modes"

  @impl Mix.Task
  def run(args) do
    load_env_file()
    Mix.Task.run("app.start")

    # Parse command-line arguments
    {opts, _remaining, invalid} =
      OptionParser.parse(
        args,
        switches: [
          source: :string,
          username: :string,
          mode: :string,
          limit: :integer,
          date_range: :string,
          status: :boolean,
          include_replies: :boolean,
          dry_run: :boolean,
          force: :boolean
        ],
        aliases: [
          s: :source,
          u: :username,
          m: :mode,
          l: :limit,
          d: :dry_run,
          f: :force,
          r: :include_replies
        ]
      )

    # Handle invalid options
    if length(invalid) > 0 do
      Mix.shell().error("Invalid options: #{inspect(invalid)}")
      print_usage()
      System.halt(1)
    end

    # Status check mode - show analysis without importing
    if opts[:status] do
      run_status_check(opts)
    else
      # Validate and run import
      case validate_options(opts) do
        {:ok, config} ->
          run_import(config)

        {:error, reason} ->
          Mix.shell().error("Error: #{reason}")
          print_usage()
          System.halt(1)
      end
    end
  end

  # Status check - show import analysis
  defp run_status_check(opts) do
    source = Keyword.get(opts, :source)
    username = Keyword.get(opts, :username)

    cond do
      is_nil(source) ->
        Mix.shell().error("Error: --status requires --source")
        System.halt(1)

      is_nil(username) ->
        Mix.shell().error("Error: --status requires --username")
        System.halt(1)

      true ->
        case ImportAnalyzer.analyze_import_status(source, username) do
          {:ok, analysis} ->
            output = ImportAnalyzer.format_status(analysis)
            Mix.shell().info(output)

          {:error, {:source_not_found, _}} ->
            Mix.shell().error("Error: Source '#{source}' not found in database.")
            System.halt(1)

          {:error, reason} ->
            Mix.shell().error("Error: #{inspect(reason)}")
            System.halt(1)
        end
    end
  end

  defp validate_options(opts) do
    source = Keyword.get(opts, :source)
    username = Keyword.get(opts, :username)
    mode = Keyword.get(opts, :mode, "newest")
    limit = Keyword.get(opts, :limit)
    date_range = Keyword.get(opts, :date_range)
    include_replies = Keyword.get(opts, :include_replies, false)
    dry_run = Keyword.get(opts, :dry_run, false)
    force = Keyword.get(opts, :force, false)

    with :ok <- validate_required(source, username),
         :ok <- validate_source(source),
         {:ok, mode_atom} <- validate_mode(mode),
         {:ok, parsed_date_range} <- validate_date_range(mode_atom, date_range),
         {:ok, final_limit} <- determine_limit(mode_atom, limit, source, username) do
      {:ok,
       %{
         source: source,
         username: username,
         mode: mode_atom,
         limit: final_limit,
         date_range: parsed_date_range,
         include_replies: include_replies,
         dry_run: dry_run,
         # TODO: Implement force flag to reset classification status when re-importing
         # Currently, create_or_update_content already does smart upserts that preserve
         # classification data, so this flag is reserved for forcing re-classification
         force: force
       }}
    end
  end

  defp validate_required(nil, _), do: {:error, "Missing required option: --source"}
  defp validate_required(_, nil), do: {:error, "Missing required option: --username"}
  defp validate_required(_, _), do: :ok

  defp validate_source("truth_social"), do: :ok

  defp validate_source(source),
    do: {:error, "Unsupported source: #{source}. Currently only 'truth_social' is supported."}

  defp validate_mode("newest"), do: {:ok, :newest}
  defp validate_mode("backfill"), do: {:ok, :backfill}
  defp validate_mode("full"), do: {:ok, :full}
  defp validate_mode(mode), do: {:error, "Invalid mode: #{mode}. Must be: newest, backfill, or full"}

  defp validate_date_range(:backfill, nil) do
    {:error, "Mode 'backfill' requires --date-range option"}
  end

  defp validate_date_range(:backfill, date_range) do
    case String.split(date_range, " ") do
      [start_str, end_str] ->
        with {:ok, start_date} <- Date.from_iso8601(start_str),
             {:ok, end_date} <- Date.from_iso8601(end_str) do
          {:ok, {start_date, end_date}}
        else
          _ -> {:error, "Invalid date format. Use: YYYY-MM-DD YYYY-MM-DD"}
        end

      _ ->
        {:error, "Invalid date range format. Use: YYYY-MM-DD YYYY-MM-DD"}
    end
  end

  defp validate_date_range(_, _), do: {:ok, nil}

  # Determine fetch limit based on mode
  defp determine_limit(:newest, nil, source, username) do
    # Auto-calculate limit for incremental import
    case ImportAnalyzer.calculate_incremental_limit(source, username) do
      {:ok, calc} ->
        {:ok, calc.recommended_limit}

      {:error, _} ->
        {:ok, 100}
    end
  end

  defp determine_limit(:newest, limit, _, _) when is_integer(limit) and limit > 0 do
    {:ok, limit}
  end

  defp determine_limit(:full, nil, _, _), do: {:ok, 100}

  defp determine_limit(:full, limit, _, _) when is_integer(limit) and limit > 0 and limit <= 10_000 do
    {:ok, limit}
  end

  defp determine_limit(:full, limit, _, _) when limit > 10_000 do
    {:error, "Limit cannot exceed 10,000 posts"}
  end

  defp determine_limit(:backfill, nil, _, _), do: {:ok, 500}

  defp determine_limit(:backfill, limit, _, _) when is_integer(limit) and limit > 0 do
    {:ok, limit}
  end

  defp determine_limit(_, limit, _, _) when is_integer(limit) and limit < 1 do
    {:error, "Limit must be at least 1"}
  end

  defp determine_limit(_, _, _, _), do: {:ok, 100}

  # Main import dispatcher
  defp run_import(config) do
    print_header(config)

    if config.dry_run do
      run_dry_run(config)
    else
      case config.mode do
        :newest -> run_newest_mode(config)
        :backfill -> run_backfill_mode(config)
        :full -> run_full_mode(config)
      end
    end
  end

  # Execute actual fetch and import
  defp execute_fetch_and_import(config) do
    start_time = System.monotonic_time(:millisecond)

    # Step 1: Fetch from Apify
    Mix.shell().info("📡 STEP 1: Fetching from Apify...\n")

    case ApifyClient.fetch_posts(config.username,
           max_posts: config.limit,
           include_replies: config.include_replies
         ) do
      {:ok, posts} ->
        fetch_time = System.monotonic_time(:millisecond) - start_time
        Mix.shell().info("✅ Fetched #{length(posts)} posts in #{div(fetch_time, 1000)}s\n")

        # Filter posts by date range if backfill mode
        filtered_posts =
          if config.mode == :backfill and config.date_range do
            filter_by_date_range(posts, config.date_range)
          else
            posts
          end

        if config.mode == :backfill and length(filtered_posts) < length(posts) do
          excluded = length(posts) - length(filtered_posts)
          Mix.shell().info("🔍 Filtered to date range: #{length(filtered_posts)} posts (excluded #{excluded})\n")
        end

        # Step 2: Import to database
        import_start = System.monotonic_time(:millisecond)
        Mix.shell().info("💾 STEP 2: Importing to database...\n")

        case Importer.import_posts(filtered_posts, config.source) do
          {:ok, stats} ->
            import_time = System.monotonic_time(:millisecond) - import_start
            total_time = System.monotonic_time(:millisecond) - start_time
            print_import_stats(stats, import_time)
            print_summary(config, stats, total_time)

          {:error, {:source_not_found, source}} ->
            Mix.shell().error("\n❌ Source '#{source}' not found in database.")
            Mix.shell().error("   Run 'mix ecto.seed' to create default sources.")
            System.halt(1)

          {:error, reason} ->
            Mix.shell().error("\n❌ Import failed: #{inspect(reason)}")
            System.halt(1)
        end

      {:error, :missing_user_id} ->
        Mix.shell().error("\n❌ Missing APIFY_USER_ID environment variable")
        Mix.shell().error("   Set it in your .env file")
        System.halt(1)

      {:error, :missing_api_token} ->
        Mix.shell().error("\n❌ Missing APIFY_PERSONAL_API_TOKEN environment variable")
        Mix.shell().error("   Set it in your .env file")
        System.halt(1)

      {:error, :timeout} ->
        Mix.shell().error("\n❌ Timeout waiting for Apify actor (10 minutes)")
        Mix.shell().error("   Try reducing --limit or check Apify dashboard")
        System.halt(1)

      {:error, :actor_failed} ->
        Mix.shell().error("\n❌ Apify actor run failed")
        Mix.shell().error("   Check logs above or Apify dashboard for details")
        System.halt(1)

      {:error, reason} ->
        Mix.shell().error("\n❌ Fetch failed: #{inspect(reason)}")
        System.halt(1)
    end
  end

  # Mode: newest - Incremental import of new posts
  defp run_newest_mode(config) do
    Mix.shell().info("\n🔄 MODE: Incremental Import (newest posts only)\n")

    # Show calculated limit reasoning
    case ImportAnalyzer.calculate_incremental_limit(config.source, config.username) do
      {:ok, calc} ->
        if calc.days_since_last do
          Mix.shell().info("📊 Analysis:")
          Mix.shell().info("  Days since last import: #{calc.days_since_last}")
          Mix.shell().info("  Average posting rate: #{calc.avg_posts_per_day} posts/day")
          Mix.shell().info("  Estimated new posts: #{calc.estimated_new}")
          Mix.shell().info("  Fetching limit: #{config.limit} posts (with buffer)\n")
        end

      {:error, _} ->
        Mix.shell().info("ℹ️  No previous imports found. Using default limit: #{config.limit}\n")
    end

    execute_fetch_and_import(config)
  end

  # Mode: backfill - Fill gaps in historical data
  defp run_backfill_mode(config) do
    {start_date, end_date} = config.date_range
    Mix.shell().info("\n🔍 MODE: Backfill (filling historical gaps)\n")
    Mix.shell().info("📅 Target Date Range: #{start_date} to #{end_date}\n")

    # Note: Apify may not support date filtering, so we fetch and filter locally
    Mix.shell().info("⚠️  Note: Fetching #{config.limit} posts and filtering by date range locally")
    Mix.shell().info("   (Apify Truth Social scraper may not support server-side date filtering)\n")

    execute_fetch_and_import(config)
  end

  # Mode: full - Complete import with custom limit
  defp run_full_mode(config) do
    Mix.shell().info("\n📚 MODE: Full Import (batch processing)\n")
    Mix.shell().info("  Fetch limit: #{config.limit} posts")

    if config.limit > 500 do
      Mix.shell().info("  ⚠️  Large import detected - this may take several minutes")
      Mix.shell().info("  ⚠️  Apify actor run timeout: 10 minutes\n")
    else
      Mix.shell().info("")
    end

    execute_fetch_and_import(config)
  end

  # Dry run preview
  defp run_dry_run(config) do
    Mix.shell().info("\n🔍 DRY RUN - No data will be imported\n")
    Mix.shell().info("Configuration:")
    Mix.shell().info("  Source: #{config.source}")
    Mix.shell().info("  Username: @#{config.username}")
    Mix.shell().info("  Mode: #{config.mode}")
    Mix.shell().info("  Max posts: #{config.limit}")
    Mix.shell().info("  Include replies: #{config.include_replies}")

    if config.date_range do
      {start_date, end_date} = config.date_range
      Mix.shell().info("  Date range: #{start_date} to #{end_date}")
    end

    Mix.shell().info("")

    case ApifyClient.get_credentials() do
      {:ok, _credentials} ->
        Mix.shell().info("✅ Apify credentials found")
        Mix.shell().info("")
        Mix.shell().info("Would fetch up to #{config.limit} posts from @#{config.username}")

        if config.mode == :newest do
          case ImportAnalyzer.calculate_incremental_limit(config.source, config.username) do
            {:ok, calc} when not is_nil(calc.days_since_last) ->
              Mix.shell().info("  Estimated new posts: ~#{calc.estimated_new}")

            _ ->
              nil
          end
        end

        Mix.shell().info("")
        Mix.shell().info("Run without --dry-run to actually fetch and import.")

      {:error, :missing_user_id} ->
        Mix.shell().error("❌ Missing APIFY_USER_ID environment variable")
        System.halt(1)

      {:error, :missing_api_token} ->
        Mix.shell().error("❌ Missing APIFY_PERSONAL_API_TOKEN environment variable")
        System.halt(1)
    end
  end

  # Filter posts by date range (for backfill mode)
  defp filter_by_date_range(posts, {start_date, end_date}) do
    Enum.filter(posts, fn post ->
      case Importer.parse_datetime(post["createdAt"]) do
        nil ->
          false

        datetime ->
          post_date = DateTime.to_date(datetime)
          Date.compare(post_date, start_date) != :lt and Date.compare(post_date, end_date) != :gt
      end
    end)
  end

  defp print_header(config) do
    Mix.shell().info("\n" <> String.duplicate("=", 80))
    Mix.shell().info("📥 Content Ingestion - #{String.upcase(config.source)}")
    Mix.shell().info(String.duplicate("=", 80))
    Mix.shell().info("Username: @#{config.username}")
    Mix.shell().info("Mode: #{config.mode}")
    Mix.shell().info("Fetch limit: #{config.limit}")
    Mix.shell().info("Include replies: #{config.include_replies}")

    if config.date_range do
      {start_date, end_date} = config.date_range
      Mix.shell().info("Date range: #{start_date} to #{end_date}")
    end

    Mix.shell().info(String.duplicate("=", 80))
  end

  defp print_import_stats(stats, import_time) do
    Mix.shell().info("✅ Import complete in #{div(import_time, 1000)}s\n")
    Mix.shell().info("   Total processed: #{stats.total}")
    Mix.shell().info("   Imported/Updated: #{stats.imported}")

    if stats.failed > 0 do
      Mix.shell().info("   Failed: #{stats.failed}")
    end
  end

  defp print_summary(config, stats, total_time) do
    Mix.shell().info("\n" <> String.duplicate("=", 80))
    Mix.shell().info("✅ INGESTION COMPLETE - Mode: #{String.upcase(to_string(config.mode))}")
    Mix.shell().info(String.duplicate("=", 80))
    Mix.shell().info("Total time: #{div(total_time, 1000)}s")
    Mix.shell().info("Successfully imported: #{stats.imported} posts")
    Mix.shell().info(String.duplicate("=", 80))
    Mix.shell().info("")

    Mix.shell().info("Next steps:")
    Mix.shell().info("  • Run: mix ingest.content --status -s #{config.source} -u #{config.username}")
    Mix.shell().info("  • Run: mix classify.contents --all --multi-model")
    Mix.shell().info("")
  end

  defp print_usage do
    Mix.shell().info("""

    Usage:
      mix ingest.content --source SOURCE --username USERNAME [OPTIONS]

    Required:
      --source, -s          Content source (currently: truth_social)
      --username, -u        Username/profile to fetch

    Options:
      --mode, -m MODE       Import mode: newest, backfill, full (default: newest)
      --limit, -l N         Max posts to fetch (auto-calculated for 'newest')
      --date-range "S E"    Date range for backfill: "YYYY-MM-DD YYYY-MM-DD"
      --status              Show import status and recommendations
      --include-replies, -r Include replies in results
      --dry-run, -d         Preview without importing
      --force, -f           [Reserved] Force re-classification (not yet implemented)

    Modes:
      newest      Import only new posts since last import (incremental, default)
      backfill    Fill gaps in specified date range
      full        Complete import with custom limit

    Examples:
      # Check status and get recommendations
      mix ingest.content --status -s truth_social -u realDonaldTrump

      # Daily incremental import (auto-calculated limit)
      mix ingest.content -s truth_social -u realDonaldTrump --mode newest

      # Fill historical gap
      mix ingest.content -s truth_social -u realDonaldTrump --mode backfill --date-range "2024-03-15 2024-03-22"

      # Large full import
      mix ingest.content -s truth_social -u realDonaldTrump --mode full --limit 1000

      # Dry run preview
      mix ingest.content -s truth_social -u realDonaldTrump --mode newest --dry-run
    """)
  end

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
end
