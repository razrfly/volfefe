# Test Apify actor with minimal posts (5 posts)
# Usage: elixir priv/repo/scripts/test_apify_actor.exs

Mix.install([{:req, "~> 0.4.0"}, {:jason, "~> 1.4"}])

defmodule ApifyTest do
  def run do
    # Load credentials from environment
    user_id = System.get_env("APIFY_USER_ID")
    api_token = System.get_env("APIFY_PERSONAL_API_TOKEN")

    if !user_id or !api_token do
      IO.puts("❌ Missing Apify credentials")
      IO.puts("   Please set APIFY_USER_ID and APIFY_PERSONAL_API_TOKEN environment variables")
      System.halt(1)
    end

    # Actor configuration
    actor_id = "tri_angle~truth-scraper"
    base_url = "https://api.apify.com/v2"

    # Actor input - fetch only 5 posts for testing
    # Note: Actor expects "profiles" as an array, not a single "username"
    # resultsType must be "posts" to get actual posts, not "profile-details"
    run_input = %{
      "profiles" => ["realDonaldTrump"],
      "maxPosts" => 5,
      "includeReplies" => false,
      "resultsType" => "posts"
    }

    IO.puts("🚀 Starting Apify actor: #{actor_id}")
    IO.puts("   Username: realDonaldTrump")
    IO.puts("   Max posts: 5")
    IO.puts("")

    # Step 1: Start actor run
    start_url = "#{base_url}/acts/#{actor_id}/runs?token=#{api_token}"

    IO.puts("📡 Starting actor run...")

    response = Req.post!(start_url, json: run_input)

    case response.status do
      201 ->
        run_id = response.body["data"]["id"]
        IO.puts("✅ Actor run started")
        IO.puts("   Run ID: #{run_id}")
        IO.puts("")

        # Step 2: Poll for completion
        IO.puts("⏳ Waiting for actor to finish...")
        IO.write("   ")
        wait_for_completion(base_url, run_id, api_token)
        IO.puts("")

        # Step 3: Get dataset ID
        dataset_id = get_dataset_id(base_url, run_id, api_token)
        IO.puts("📊 Dataset ID: #{dataset_id}")

        # Step 4: Fetch results
        IO.puts("📥 Fetching results...")
        posts = fetch_dataset(base_url, dataset_id, api_token)

        # Step 5: Display results
        IO.puts("")
        IO.puts("✅ Successfully fetched #{length(posts)} posts")
        IO.puts("")
        IO.puts("=" |> String.duplicate(80))

        Enum.with_index(posts, 1)
        |> Enum.each(fn {post, idx} ->
          IO.puts("")
          IO.puts("Post #{idx}:")
          IO.puts("  ID: #{inspect(post["id"] || post["postId"])}")
          IO.puts("  Author: #{inspect(post["author"] || post["username"])}")

          IO.puts(
            "  Date: #{inspect(post["created_at"] || post["createdAt"] || post["timestamp"])}"
          )

          text = post["content"] || post["text"] || post["body"] || ""

          preview =
            if String.length(text) > 100,
              do: String.slice(text, 0..100) <> "...",
              else: text

          IO.puts("  Text: #{inspect(preview)}")
          IO.puts("  URL: #{inspect(post["url"])}")
        end)

        IO.puts("")
        IO.puts("=" |> String.duplicate(80))
        IO.puts("")

        # Step 6: Save to file for inspection
        output_file = "test_posts.json"
        File.write!(output_file, Jason.encode!(posts, pretty: true))
        IO.puts("💾 Saved to #{output_file}")

        # Step 7: Show field mapping
        IO.puts("")
        IO.puts("📋 Field Mapping Analysis:")

        if length(posts) > 0 do
          sample = List.first(posts)
          IO.puts("   Available fields: #{inspect(Map.keys(sample))}")
        end

        # Step 8: Check costs
        IO.puts("")
        IO.puts("💰 Cost Information:")
        IO.puts("   Check Apify dashboard: https://console.apify.com/account/usage-and-billing")
        IO.puts("   Expected cost: ~$0.01-0.02")

      status ->
        IO.puts("❌ Failed to start actor: HTTP #{status}")
        IO.inspect(response.body, pretty: true)
        System.halt(1)
    end
  end

  # Helper: Wait for actor run to complete
  defp wait_for_completion(base_url, run_id, token, attempts \\ 0) do
    if attempts > 120 do
      # 10 minute timeout
      IO.puts("")
      IO.puts("❌ Timeout waiting for actor (10 minutes)")
      System.halt(1)
    end

    url = "#{base_url}/actor-runs/#{run_id}?token=#{token}"
    response = Req.get!(url)

    status = response.body["data"]["status"]

    case status do
      "SUCCEEDED" ->
        IO.puts("")
        IO.puts("✅ Actor completed successfully")
        duration = response.body["data"]["stats"]["runTimeSecs"]
        IO.puts("   Duration: #{duration}s")

      "FAILED" ->
        IO.puts("")
        IO.puts("❌ Actor failed")
        IO.puts("")
        IO.puts("📋 Full run details:")
        IO.inspect(response.body["data"], pretty: true, limit: :infinity)

        # Also try to fetch logs
        IO.puts("")
        IO.puts("📜 Checking actor logs...")
        logs_url = "#{base_url}/actor-runs/#{run_id}/log?token=#{token}"
        logs_response = Req.get!(logs_url)

        if logs_response.status == 200 do
          IO.puts("")
          IO.puts("Actor log output:")
          IO.puts(logs_response.body)
        end

        System.halt(1)

      "RUNNING" ->
        IO.write(".")
        Process.sleep(5000)
        # Wait 5 seconds
        wait_for_completion(base_url, run_id, token, attempts + 1)

      "READY" ->
        IO.write(".")
        Process.sleep(5000)
        wait_for_completion(base_url, run_id, token, attempts + 1)

      _other ->
        IO.write(".")
        Process.sleep(5000)
        wait_for_completion(base_url, run_id, token, attempts + 1)
    end
  end

  # Helper: Get dataset ID from run
  defp get_dataset_id(base_url, run_id, token) do
    url = "#{base_url}/actor-runs/#{run_id}?token=#{token}"
    response = Req.get!(url)
    response.body["data"]["defaultDatasetId"]
  end

  # Helper: Fetch dataset items
  defp fetch_dataset(base_url, dataset_id, token) do
    url = "#{base_url}/datasets/#{dataset_id}/items?token=#{token}"
    response = Req.get!(url)

    case response.status do
      200 ->
        response.body

      _ ->
        IO.puts("❌ Failed to fetch dataset: HTTP #{response.status}")
        []
    end
  end
end

ApifyTest.run()
