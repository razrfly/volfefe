# Apify Field Mapping Documentation

## Overview
Mapping between Apify Truth Social Scraper output and Volfefe Machine `contents` table schema.

## Actor Configuration
- **Actor ID**: `tri_angle~truth-scraper`
- **Required Input Parameters**:
  - `profiles`: Array of usernames (e.g., `["realDonaldTrump"]`)
  - `resultsType`: Must be `"posts"` to get posts (not `"profile-details"`)
  - `maxPosts`: Number of posts to fetch (seems to default to 100 minimum)
  - `includeReplies`: Boolean to include/exclude replies

## Field Mapping

### Core Fields (Required)

| Apify Field | DB Column | Type | Transformation |
|-------------|-----------|------|----------------|
| `id` | `external_id` | string | Direct mapping |
| `username` | `author` | string | Direct mapping |
| `content` | `text` | text | Strip HTML tags for clean text |
| `createdAt` | `published_at` | utc_datetime | Parse ISO 8601 datetime |
| `url` | `url` | string | Direct mapping |

### Metadata Fields (Optional - Store in `meta` JSONB)

| Apify Field | Description | Example |
|-------------|-------------|---------|
| `accountId` | Truth Social account ID | "107780257626128497" |
| `favouritesCount` | Number of likes/favorites | 27275 |
| `reblogsCount` | Number of shares/retruth | 6067 |
| `repliesCount` | Number of replies | 2651 |
| `language` | Post language code | "en" |
| `mediaAttachments` | Array of media URLs | [] |
| `mentions` | Array of mentioned users | [] |
| `type` | Post type | "post" |
| `inReplyToId` | Parent post ID if reply | null |
| `inReplyToAccountId` | Parent account if reply | null |
| `sensitive` | Content warning flag | false |
| `muted` | Muted status | false |
| `pinned` | Pinned status | false |

## Sample Apify Response

```json
{
  "accountId": "107780257626128497",
  "content": "<p>I am on my way to Malaysia...</p>",
  "createdAt": "2025-10-25T22:15:50.076Z",
  "favouritesCount": 27275,
  "id": "115437112529618205",
  "inReplyToAccountId": null,
  "inReplyToId": null,
  "input": "realDonaldTrump",
  "language": "en",
  "mediaAttachments": [],
  "mentions": [],
  "muted": false,
  "pinned": false,
  "reblogsCount": 6067,
  "repliesCount": 2651,
  "sensitive": false,
  "type": "post",
  "url": "https://truthsocial.com/@realDonaldTrump/115437112529618205",
  "username": "realDonaldTrump"
}
```

## Transformation Notes

### HTML Content Stripping
The `content` field contains HTML tags. For ML analysis (FinBERT), we need plain text:

**Input**:
```html
<p>I am on my way to Malaysia, where I will sign the great Peace Deal...</p>
```

**Output**:
```text
I am on my way to Malaysia, where I will sign the great Peace Deal...
```

Use a library like:
- Elixir: `HtmlSanitizer.strip_tags/1` or `Floki.text/1`
- Keep links for context if needed

### Datetime Parsing
ISO 8601 format from Apify → Phoenix DateTime:
```elixir
{:ok, datetime, _} = DateTime.from_iso8601("2025-10-25T22:15:50.076Z")
```

### Metadata Storage Strategy
Store engagement metrics and additional fields in `meta` JSONB:
```elixir
%{
  "engagement" => %{
    "favorites" => 27275,
    "reblogs" => 6067,
    "replies" => 2651
  },
  "language" => "en",
  "has_media" => false,
  "is_reply" => false
}
```

## Import Implementation Pattern

```elixir
defmodule VolfefeMachine.Adapters.ApifyAdapter do
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
          "favorites" => apify_post["favouritesCount"],
          "reblogs" => apify_post["reblogsCount"],
          "replies" => apify_post["repliesCount"]
        },
        "language" => apify_post["language"],
        "has_media" => length(apify_post["mediaAttachments"]) > 0,
        "is_reply" => apify_post["inReplyToId"] != nil
      }
    }
  end

  defp strip_html(html) do
    # Implementation using HtmlSanitizer or Floki
    html
    |> HtmlSanitizer.strip_tags()
    |> String.trim()
  end

  defp parse_datetime(iso_string) do
    case DateTime.from_iso8601(iso_string) do
      {:ok, datetime, _} -> datetime
      _ -> nil
    end
  end
end
```

## Cost Information

**Actual costs from test run (100 posts)**:
- **Start Event**: $0.0001
- **Per Result**: $0.005 (FREE tier pricing)
- **Test Cost**: $0.0001 + (100 × $0.005) = **$0.5001**

**Budget Constraints**:
- **Available Budget**: $4-5
- **Maximum Posts**: ~800-1000 posts (at $0.005 per post)
- **Recommendation**:
  - Fetch ~800 posts for $4.00 for initial backtest
  - Trump has posted 29,426+ times total
  - Focus on recent posts (last 6-12 months) for tariff-related content

## Notes
- Actor seems to return minimum 100 posts even if `maxPosts: 5` is specified
- Set `resultsType: "posts"` to get posts, not profile information
- HTML content requires stripping for clean text analysis
- Engagement metrics valuable for future analysis/filtering
