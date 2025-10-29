defmodule VolfefeMachine.Ingestion.ApifyClient do
  @moduledoc """
  Client for Apify API to fetch social media posts.

  Handles the complete workflow:
  1. Start actor run with configuration
  2. Poll for completion
  3. Fetch dataset results
  4. Handle errors and timeouts

  ## Configuration

  Requires environment variables:
  - `APIFY_USER_ID` - Your Apify user ID
  - `APIFY_PERSONAL_API_TOKEN` - Your API token

  ## Example

      iex> ApifyClient.fetch_posts("realDonaldTrump", max_posts: 100)
      {:ok, [%{"id" => "123", "content" => "...", ...}, ...]}
  """

  require Logger

  @base_url "https://api.apify.com/v2"
  @actor_id "tri_angle~truth-scraper"
  @poll_interval 5_000
  @max_poll_attempts 120

  @doc """
  Fetch posts from Truth Social for a given username.

  ## Options

    * `:max_posts` - Maximum number of posts to fetch (default: 100)
    * `:include_replies` - Include replies in results (default: false)

  ## Returns

    * `{:ok, posts}` - List of post maps from Apify
    * `{:error, reason}` - Error details
  """
  def fetch_posts(username, opts \\ []) do
    max_posts = Keyword.get(opts, :max_posts, 100)
    include_replies = Keyword.get(opts, :include_replies, false)

    Logger.info("Starting Apify fetch for @#{username} (max: #{max_posts} posts)")

    with {:ok, credentials} <- get_credentials(),
         {:ok, run_id} <- start_actor_run(username, max_posts, include_replies, credentials),
         {:ok, _duration} <- wait_for_completion(run_id, credentials),
         {:ok, dataset_id} <- get_dataset_id(run_id, credentials),
         {:ok, posts} <- fetch_dataset(dataset_id, credentials) do
      Logger.info("Successfully fetched #{length(posts)} posts")
      {:ok, posts}
    else
      {:error, reason} = error ->
        Logger.error("Apify fetch failed: #{inspect(reason)}")
        error
    end
  end

  @doc """
  Get Apify credentials from environment variables.
  """
  def get_credentials do
    user_id = System.get_env("APIFY_USER_ID")
    api_token = System.get_env("APIFY_PERSONAL_API_TOKEN")

    cond do
      !user_id ->
        {:error, :missing_user_id}

      !api_token ->
        {:error, :missing_api_token}

      true ->
        {:ok, %{user_id: user_id, api_token: api_token}}
    end
  end

  # Start an Apify actor run
  defp start_actor_run(username, max_posts, include_replies, credentials) do
    url = "#{@base_url}/acts/#{@actor_id}/runs?token=#{credentials.api_token}"

    run_input = %{
      "profiles" => [username],
      "maxPosts" => max_posts,
      "includeReplies" => include_replies,
      "resultsType" => "posts"
    }

    Logger.info("Starting Apify actor run...")

    case Req.post(url, json: run_input, receive_timeout: 30_000) do
      {:ok, %{status: 201, body: body}} ->
        run_id = body["data"]["id"]
        Logger.info("Actor run started: #{run_id}")
        {:ok, run_id}

      {:ok, %{status: status, body: body}} ->
        Logger.error("Failed to start actor: HTTP #{status}")
        {:error, {:http_error, status, body}}

      {:error, exception} ->
        Logger.error("Network error starting actor: #{inspect(exception)}")
        {:error, {:network_error, exception}}
    end
  end

  # Poll for actor run completion
  defp wait_for_completion(run_id, credentials, attempt \\ 1) do
    if attempt > @max_poll_attempts do
      {:error, :timeout}
    else
      url = "#{@base_url}/actor-runs/#{run_id}?token=#{credentials.api_token}"

      case Req.get(url, receive_timeout: 30_000) do
        {:ok, %{status: 200, body: body}} ->
          status = body["data"]["status"]
          handle_run_status(status, run_id, credentials, attempt, body)

        {:ok, %{status: status}} ->
          {:error, {:http_error, status}}

        {:error, exception} ->
          {:error, {:network_error, exception}}
      end
    end
  end

  defp handle_run_status("SUCCEEDED", _run_id, _credentials, _attempt, body) do
    duration = body["data"]["stats"]["runTimeSecs"]
    Logger.info("Actor completed successfully in #{duration}s")
    {:ok, duration}
  end

  defp handle_run_status("FAILED", run_id, credentials, _attempt, body) do
    Logger.error("Actor run failed")
    Logger.error("Run details: #{inspect(body["data"], pretty: true)}")

    # Try to fetch logs for debugging
    fetch_logs(run_id, credentials)

    {:error, :actor_failed}
  end

  defp handle_run_status(status, run_id, credentials, attempt, _body)
       when status in ["RUNNING", "READY"] do
    if rem(attempt, 6) == 0 do
      # Log every 30 seconds (6 * 5s)
      Logger.info("Still waiting... (#{attempt * 5}s elapsed)")
    end

    Process.sleep(@poll_interval)
    wait_for_completion(run_id, credentials, attempt + 1)
  end

  defp handle_run_status(_other_status, run_id, credentials, attempt, _body) do
    # Unknown status, keep polling
    Process.sleep(@poll_interval)
    wait_for_completion(run_id, credentials, attempt + 1)
  end

  # Fetch actor logs for debugging
  defp fetch_logs(run_id, credentials) do
    url = "#{@base_url}/actor-runs/#{run_id}/log?token=#{credentials.api_token}"

    case Req.get(url, receive_timeout: 30_000) do
      {:ok, %{status: 200, body: logs}} ->
        Logger.error("Actor logs:\n#{logs}")

      _ ->
        Logger.error("Could not fetch actor logs")
    end
  end

  # Get dataset ID from completed run
  defp get_dataset_id(run_id, credentials) do
    url = "#{@base_url}/actor-runs/#{run_id}?token=#{credentials.api_token}"

    case Req.get(url, receive_timeout: 30_000) do
      {:ok, %{status: 200, body: body}} ->
        dataset_id = body["data"]["defaultDatasetId"]
        Logger.info("Dataset ID: #{dataset_id}")
        {:ok, dataset_id}

      {:ok, %{status: status}} ->
        {:error, {:http_error, status}}

      {:error, exception} ->
        {:error, {:network_error, exception}}
    end
  end

  # Fetch dataset items
  defp fetch_dataset(dataset_id, credentials) do
    url = "#{@base_url}/datasets/#{dataset_id}/items?token=#{credentials.api_token}"

    Logger.info("Fetching dataset items...")

    case Req.get(url, receive_timeout: 30_000) do
      {:ok, %{status: 200, body: posts}} when is_list(posts) ->
        {:ok, posts}

      {:ok, %{status: 200, body: body}} ->
        # Sometimes Apify returns object instead of array
        {:error, {:unexpected_format, body}}

      {:ok, %{status: status}} ->
        {:error, {:http_error, status}}

      {:error, exception} ->
        {:error, {:network_error, exception}}
    end
  end
end
