# Import Apify posts from test_posts.json into database
# Usage: mix run priv/repo/scripts/import_apify_posts.exs

alias VolfefeMachine.Content

defmodule ApifyImporter do
  @doc """
  Strips HTML tags from content.
  Simple regex approach - replaces <tag>content</tag> with just content.
  """
  def strip_html(nil), do: nil
  def strip_html(""), do: ""

  def strip_html(html) do
    html
    # Remove HTML tags
    |> String.replace(~r/<[^>]+>/, "")
    # Decode common HTML entities
    |> String.replace("&lt;", "<")
    |> String.replace("&gt;", ">")
    |> String.replace("&amp;", "&")
    |> String.replace("&quot;", "\"")
    |> String.replace("&#39;", "'")
    |> String.replace("&nbsp;", " ")
    # Clean up whitespace
    |> String.trim()
  end

  @doc """
  Parses ISO 8601 datetime string to DateTime.
  """
  def parse_datetime(nil), do: nil

  def parse_datetime(iso_string) do
    case DateTime.from_iso8601(iso_string) do
      {:ok, datetime, _} -> datetime
      _ -> nil
    end
  end

  @doc """
  Transforms an Apify post to our database schema.
  """
  def transform_post(apify_post, source_id) do
    %{
      source_id: source_id,
      external_id: apify_post["id"],
      author: apify_post["username"],
      text: strip_html(apify_post["content"]),
      url: apify_post["url"],
      published_at: parse_datetime(apify_post["createdAt"]),
      meta: %{
        "engagement" => %{
          "favorites" => apify_post["favouritesCount"] || 0,
          "reblogs" => apify_post["reblogsCount"] || 0,
          "replies" => apify_post["repliesCount"] || 0
        },
        "language" => apify_post["language"],
        "has_media" => length(apify_post["mediaAttachments"] || []) > 0,
        "is_reply" => apify_post["inReplyToId"] != nil,
        "account_id" => apify_post["accountId"]
      }
    }
  end

  @doc """
  Imports posts from a JSON file.
  """
  def import_from_file(file_path) do
    IO.puts("🚀 Starting Apify import from #{file_path}")
    IO.puts("")

    # Step 1: Read JSON file
    IO.puts("📖 Reading JSON file...")

    posts =
      case File.read(file_path) do
        {:ok, content} ->
          Jason.decode!(content)

        {:error, reason} ->
          IO.puts("❌ Failed to read file: #{inspect(reason)}")
          System.halt(1)
      end

    IO.puts("✅ Found #{length(posts)} posts")
    IO.puts("")

    # Step 2: Get or create Truth Social source
    IO.puts("🔍 Looking up Truth Social source...")

    source =
      case Content.get_source_by_name!("truth_social") do
        nil ->
          IO.puts("❌ Source 'truth_social' not found. Run seeds first!")
          System.halt(1)

        source ->
          IO.puts("✅ Found source: #{source.name} (ID: #{source.id})")
          source
      end

    IO.puts("")

    # Step 3: Import posts
    IO.puts("💾 Importing posts...")
    IO.puts("")

    results =
      Enum.with_index(posts, 1)
      |> Enum.map(fn {post, idx} ->
        attrs = transform_post(post, source.id)

        case Content.create_or_update_content(attrs) do
          {:ok, content} ->
            if rem(idx, 10) == 0 do
              IO.write(".")
            end

            {:ok, content}

          {:error, changeset} ->
            IO.puts("")
            IO.puts("❌ Failed to import post #{post["id"]}:")
            IO.inspect(changeset.errors, pretty: true)
            {:error, changeset}
        end
      end)

    IO.puts("")
    IO.puts("")

    # Step 4: Report results
    successes = Enum.count(results, fn {status, _} -> status == :ok end)
    failures = Enum.count(results, fn {status, _} -> status == :error end)

    IO.puts("=" |> String.duplicate(80))
    IO.puts("📊 Import Summary:")
    IO.puts("   Total posts: #{length(posts)}")
    IO.puts("   ✅ Successful: #{successes}")
    IO.puts("   ❌ Failed: #{failures}")
    IO.puts("=" |> String.duplicate(80))
    IO.puts("")

    # Step 5: Show sample data
    if successes > 0 do
      IO.puts("📋 Sample imported post:")
      sample = List.first(posts)
      transformed = transform_post(sample, source.id)

      IO.puts("   External ID: #{transformed.external_id}")
      IO.puts("   Author: #{transformed.author}")
      IO.puts("   Published: #{transformed.published_at}")
      IO.puts("   Text preview: #{String.slice(transformed.text || "", 0..100)}...")
      IO.puts("")
      IO.puts("   Engagement:")
      IO.puts("     Favorites: #{transformed.meta["engagement"]["favorites"]}")
      IO.puts("     Reblogs: #{transformed.meta["engagement"]["reblogs"]}")
      IO.puts("     Replies: #{transformed.meta["engagement"]["replies"]}")
    end

    IO.puts("")

    # Step 6: Update source last_fetched_at
    if successes > 0 do
      Content.touch_source_fetched!(source.id)
      IO.puts("✅ Updated source last_fetched_at timestamp")
    end

    IO.puts("")
    IO.puts("🎉 Import complete!")
  end
end

# Run the import
ApifyImporter.import_from_file("test_posts.json")
