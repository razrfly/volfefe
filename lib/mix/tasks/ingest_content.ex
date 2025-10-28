defmodule Mix.Tasks.Ingest.Content do
  @moduledoc """
  Unified task to fetch and import content from external sources.

  Combines Apify API fetching and database import into a single command.

  ## Usage

      # Fetch 100 posts from Truth Social
      mix ingest.content --source truth_social --username realDonaldTrump --limit 100

      # Include replies in results
      mix ingest.content --source truth_social --username realDonaldTrump --limit 50 --include-replies

      # Dry run to see what would be fetched
      mix ingest.content --source truth_social --username realDonaldTrump --limit 10 --dry-run

  ## Options

    * `--source` - Content source (currently only "truth_social" supported)
    * `--username` - Username/profile to fetch (e.g., "realDonaldTrump")
    * `--limit` - Maximum number of posts to fetch (default: 100)
    * `--include-replies` - Include replies in results (default: false)
    * `--dry-run` - Show what would be fetched without importing

  ## Examples

      # Quick test with 10 posts
      mix ingest.content --source truth_social --username realDonaldTrump --limit 10

      # Production run with more posts
      mix ingest.content --source truth_social --username realDonaldTrump --limit 500
  """

  use Mix.Task

  alias VolfefeMachine.Ingestion.ApifyClient
  alias VolfefeMachine.Ingestion.Importer

  @shortdoc "Fetch and import content from external sources"

  @impl Mix.Task
  def run(args) do
    # Load .env file if it exists
    load_env_file()

    # Start application to get Repo and database access
    Mix.Task.run("app.start")

    # Parse command-line arguments
    {opts, _remaining, invalid} =
      OptionParser.parse(
        args,
        switches: [
          source: :string,
          username: :string,
          limit: :integer,
          include_replies: :boolean,
          dry_run: :boolean
        ],
        aliases: [
          s: :source,
          u: :username,
          l: :limit,
          r: :include_replies,
          d: :dry_run
        ]
      )

    # Handle invalid options
    if length(invalid) > 0 do
      Mix.shell().error("Invalid options: #{inspect(invalid)}")
      print_usage()
      System.halt(1)
    end

    # Validate required parameters
    case validate_options(opts) do
      {:ok, config} ->
        run_ingestion(config)

      {:error, reason} ->
        Mix.shell().error("Error: #{reason}")
        print_usage()
        System.halt(1)
    end
  end

  defp validate_options(opts) do
    source = Keyword.get(opts, :source)
    username = Keyword.get(opts, :username)
    limit = Keyword.get(opts, :limit, 100)
    include_replies = Keyword.get(opts, :include_replies, false)
    dry_run = Keyword.get(opts, :dry_run, false)

    cond do
      is_nil(source) ->
        {:error, "Missing required option: --source"}

      source != "truth_social" ->
        {:error, "Unsupported source: #{source}. Currently only 'truth_social' is supported."}

      is_nil(username) ->
        {:error, "Missing required option: --username"}

      limit < 1 ->
        {:error, "Limit must be at least 1"}

      limit > 10_000 ->
        {:error, "Limit cannot exceed 10,000 posts"}

      true ->
        {:ok,
         %{
           source: source,
           username: username,
           limit: limit,
           include_replies: include_replies,
           dry_run: dry_run
         }}
    end
  end

  defp run_ingestion(config) do
    print_header(config)

    if config.dry_run do
      run_dry_run(config)
    else
      run_full_ingestion(config)
    end
  end

  defp run_dry_run(config) do
    Mix.shell().info("\n🔍 DRY RUN - No data will be imported\n")
    Mix.shell().info("Configuration:")
    Mix.shell().info("  Source: #{config.source}")
    Mix.shell().info("  Username: @#{config.username}")
    Mix.shell().info("  Max posts: #{config.limit}")
    Mix.shell().info("  Include replies: #{config.include_replies}")
    Mix.shell().info("")

    case ApifyClient.get_credentials() do
      {:ok, _credentials} ->
        Mix.shell().info("✅ Apify credentials found")
        Mix.shell().info("")
        Mix.shell().info("Would fetch up to #{config.limit} posts from @#{config.username}")
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

  defp run_full_ingestion(config) do
    start_time = System.monotonic_time(:millisecond)

    # Step 1: Fetch from Apify
    Mix.shell().info("\n📡 STEP 1: Fetching from Apify...\n")

    case ApifyClient.fetch_posts(config.username,
           max_posts: config.limit,
           include_replies: config.include_replies
         ) do
      {:ok, posts} ->
        fetch_time = System.monotonic_time(:millisecond) - start_time
        Mix.shell().info("\n✅ Fetched #{length(posts)} posts in #{div(fetch_time, 1000)}s\n")

        # Step 2: Import to database
        import_start = System.monotonic_time(:millisecond)
        Mix.shell().info("💾 STEP 2: Importing to database...\n")

        case Importer.import_posts(posts, config.source) do
          {:ok, stats} ->
            import_time = System.monotonic_time(:millisecond) - import_start
            print_import_stats(stats, import_time)

            total_time = System.monotonic_time(:millisecond) - start_time
            print_summary(stats, total_time)

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

  defp print_header(config) do
    Mix.shell().info("\n" <> String.duplicate("=", 80))
    Mix.shell().info("📥 Content Ingestion - #{String.upcase(config.source)}")
    Mix.shell().info(String.duplicate("=", 80))
    Mix.shell().info("Username: @#{config.username}")
    Mix.shell().info("Max posts: #{config.limit}")
    Mix.shell().info("Include replies: #{config.include_replies}")
  end

  defp print_import_stats(stats, import_time) do
    Mix.shell().info("✅ Import complete in #{div(import_time, 1000)}s\n")
    Mix.shell().info("   Total processed: #{stats.total}")
    Mix.shell().info("   Imported: #{stats.imported}")

    if stats.failed > 0 do
      Mix.shell().info("   Failed: #{stats.failed}")
    end
  end

  defp print_summary(stats, total_time) do
    Mix.shell().info("\n" <> String.duplicate("=", 80))
    Mix.shell().info("✅ INGESTION COMPLETE")
    Mix.shell().info(String.duplicate("=", 80))
    Mix.shell().info("Total time: #{div(total_time, 1000)}s")
    Mix.shell().info("Successfully imported: #{stats.imported} posts")
    Mix.shell().info(String.duplicate("=", 80))
    Mix.shell().info("")

    Mix.shell().info("Next steps:")
    Mix.shell().info("  • Run 'mix classify.contents --all --multi-model' to classify")
    Mix.shell().info("  • Check database with 'psql' to view imported content")
    Mix.shell().info("")
  end

  defp print_usage do
    Mix.shell().info("\nUsage:")
    Mix.shell().info("  mix ingest.content --source SOURCE --username USERNAME [OPTIONS]\n")
    Mix.shell().info("Required:")
    Mix.shell().info("  --source, -s        Content source (currently: truth_social)")
    Mix.shell().info("  --username, -u      Username/profile to fetch\n")
    Mix.shell().info("Options:")
    Mix.shell().info("  --limit, -l         Max posts to fetch (default: 100)")
    Mix.shell().info("  --include-replies   Include replies (default: false)")
    Mix.shell().info("  --dry-run           Preview without importing (default: false)\n")
    Mix.shell().info("Examples:")

    Mix.shell().info(
      "  mix ingest.content --source truth_social --username realDonaldTrump --limit 100"
    )

    Mix.shell().info(
      "  mix ingest.content -s truth_social -u realDonaldTrump -l 50 --include-replies"
    )

    Mix.shell().info("")
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
