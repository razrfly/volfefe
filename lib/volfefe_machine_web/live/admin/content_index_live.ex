defmodule VolfefeMachineWeb.Admin.ContentIndexLive do
  @moduledoc """
  Admin interface for viewing content and classification data.

  Provides real-time monitoring of ingested content from external sources
  and their associated ML-based sentiment classifications.
  """
  use VolfefeMachineWeb, :live_view

  alias VolfefeMachine.{Content, Intelligence, Repo}
  import Ecto.Query

  @impl true
  def mount(_params, _session, socket) do
    {:ok,
     socket
     |> assign(:page_title, "Content & Classifications")
     |> load_content()
     |> load_stats()}
  end

  @impl true
  def render(assigns) do
    ~H"""
    <div class="p-6">
      <div class="mb-6">
        <h1 class="text-2xl font-bold">Content & Classifications</h1>
        <p class="text-gray-600 mt-2">
          Monitor ingested content and ML-based sentiment analysis results in real-time
        </p>
      </div>

      <!-- Summary Statistics Cards -->
      <div class="grid grid-cols-1 md:grid-cols-2 lg:grid-cols-4 gap-4 mb-6">
        <!-- Total Content Card -->
        <div class="bg-white border rounded-lg p-4 shadow-sm">
          <div class="flex justify-between items-start">
            <div>
              <p class="text-sm text-gray-600 font-medium">Total Content</p>
              <p class="text-2xl font-bold text-gray-900 mt-1"><%= @stats.total_content %></p>
            </div>
            <div class="text-blue-500">
              <svg class="w-8 h-8" fill="none" stroke="currentColor" viewBox="0 0 24 24">
                <path stroke-linecap="round" stroke-linejoin="round" stroke-width="2" d="M9 12h6m-6 4h6m2 5H7a2 2 0 01-2-2V5a2 2 0 012-2h5.586a1 1 0 01.707.293l5.414 5.414a1 1 0 01.293.707V19a2 2 0 01-2 2z" />
              </svg>
            </div>
          </div>
        </div>

        <!-- Classified Card -->
        <div class="bg-white border rounded-lg p-4 shadow-sm">
          <div class="flex justify-between items-start">
            <div>
              <p class="text-sm text-gray-600 font-medium">Classified</p>
              <p class="text-2xl font-bold text-green-600 mt-1"><%= @stats.classified_count %></p>
              <p class="text-xs text-gray-500 mt-1">
                <%= format_percentage(@stats.classified_count, @stats.total_content) %>
              </p>
            </div>
            <div class="text-green-500">
              <svg class="w-8 h-8" fill="none" stroke="currentColor" viewBox="0 0 24 24">
                <path stroke-linecap="round" stroke-linejoin="round" stroke-width="2" d="M9 12l2 2 4-4m6 2a9 9 0 11-18 0 9 9 0 0118 0z" />
              </svg>
            </div>
          </div>
        </div>

        <!-- Unclassified Card -->
        <div class="bg-white border rounded-lg p-4 shadow-sm">
          <div class="flex justify-between items-start">
            <div>
              <p class="text-sm text-gray-600 font-medium">Unclassified</p>
              <p class="text-2xl font-bold text-gray-600 mt-1"><%= @stats.unclassified_count %></p>
              <p class="text-xs text-gray-500 mt-1">
                <%= format_percentage(@stats.unclassified_count, @stats.total_content) %>
              </p>
            </div>
            <div class="text-gray-400">
              <svg class="w-8 h-8" fill="none" stroke="currentColor" viewBox="0 0 24 24">
                <path stroke-linecap="round" stroke-linejoin="round" stroke-width="2" d="M12 8v4l3 3m6-3a9 9 0 11-18 0 9 9 0 0118 0z" />
              </svg>
            </div>
          </div>
        </div>

        <!-- Average Confidence Card -->
        <div class="bg-white border rounded-lg p-4 shadow-sm">
          <div class="flex justify-between items-start">
            <div>
              <p class="text-sm text-gray-600 font-medium">Avg Confidence</p>
              <p class="text-2xl font-bold text-purple-600 mt-1">
                <%= format_confidence(@stats.avg_confidence) %>
              </p>
              <p class="text-xs text-gray-500 mt-1">
                <%= @stats.classified_count %> classified items
              </p>
            </div>
            <div class="text-purple-500">
              <svg class="w-8 h-8" fill="none" stroke="currentColor" viewBox="0 0 24 24">
                <path stroke-linecap="round" stroke-linejoin="round" stroke-width="2" d="M9 19v-6a2 2 0 00-2-2H5a2 2 0 00-2 2v6a2 2 0 002 2h2a2 2 0 002-2zm0 0V9a2 2 0 012-2h2a2 2 0 012 2v10m-6 0a2 2 0 002 2h2a2 2 0 002-2m0 0V5a2 2 0 012-2h2a2 2 0 012 2v14a2 2 0 01-2 2h-2a2 2 0 01-2-2z" />
              </svg>
            </div>
          </div>
        </div>
      </div>

      <!-- Sentiment Distribution (if we have classified content) -->
      <%= if @stats.classified_count > 0 do %>
        <div class="bg-white border rounded-lg p-4 shadow-sm mb-6">
          <h3 class="text-sm font-medium text-gray-900 mb-3">Sentiment Distribution</h3>
          <div class="grid grid-cols-3 gap-4">
            <div class="text-center">
              <div class="text-2xl font-bold text-green-600"><%= @stats.sentiment_dist.positive %></div>
              <div class="text-xs text-gray-600 mt-1">Positive</div>
              <div class="text-xs text-gray-500">
                <%= format_percentage(@stats.sentiment_dist.positive, @stats.classified_count) %>
              </div>
            </div>
            <div class="text-center">
              <div class="text-2xl font-bold text-red-600"><%= @stats.sentiment_dist.negative %></div>
              <div class="text-xs text-gray-600 mt-1">Negative</div>
              <div class="text-xs text-gray-500">
                <%= format_percentage(@stats.sentiment_dist.negative, @stats.classified_count) %>
              </div>
            </div>
            <div class="text-center">
              <div class="text-2xl font-bold text-gray-600"><%= @stats.sentiment_dist.neutral %></div>
              <div class="text-xs text-gray-600 mt-1">Neutral</div>
              <div class="text-xs text-gray-500">
                <%= format_percentage(@stats.sentiment_dist.neutral, @stats.classified_count) %>
              </div>
            </div>
          </div>
        </div>
      <% end %>

      <%= if Enum.empty?(@contents) do %>
        <div class="bg-gray-50 border border-gray-200 rounded-lg p-8 text-center">
          <p class="text-gray-600 text-lg">No content found</p>
          <p class="text-gray-500 text-sm mt-2">
            Content will appear here once ingested from external sources
          </p>
        </div>
      <% else %>
        <div class="bg-white border rounded-lg shadow-sm overflow-hidden">
          <table class="min-w-full divide-y divide-gray-200">
            <thead class="bg-gray-50">
              <tr>
                <th class="px-6 py-3 text-left text-xs font-medium text-gray-500 uppercase tracking-wider">
                  Author
                </th>
                <th class="px-6 py-3 text-left text-xs font-medium text-gray-500 uppercase tracking-wider">
                  Content
                </th>
                <th class="px-6 py-3 text-left text-xs font-medium text-gray-500 uppercase tracking-wider">
                  Published
                </th>
                <th class="px-6 py-3 text-left text-xs font-medium text-gray-500 uppercase tracking-wider">
                  Status
                </th>
              </tr>
            </thead>
            <tbody class="bg-white divide-y divide-gray-200">
              <%= for content <- @contents do %>
                <tr class="hover:bg-gray-50 transition-colors">
                  <td class="px-6 py-4 whitespace-nowrap">
                    <div class="text-sm font-medium text-gray-900">
                      <%= content.author || "Unknown" %>
                    </div>
                  </td>
                  <td class="px-6 py-4">
                    <div class="text-sm text-gray-900">
                      <%= truncate_text(content.text, 150) %>
                    </div>
                  </td>
                  <td class="px-6 py-4 whitespace-nowrap">
                    <div class="text-sm text-gray-500">
                      <%= format_datetime(content.published_at) %>
                    </div>
                  </td>
                  <td class="px-6 py-4 whitespace-nowrap">
                    <%= if content.classified do %>
                      <span class="px-2 py-1 text-xs bg-green-100 text-green-800 rounded">
                        Classified
                      </span>
                    <% else %>
                      <span class="px-2 py-1 text-xs bg-gray-100 text-gray-800 rounded">
                        Unclassified
                      </span>
                    <% end %>
                  </td>
                </tr>
              <% end %>
            </tbody>
          </table>
        </div>
      <% end %>
    </div>
    """
  end

  # ========================================
  # Private Functions
  # ========================================

  defp load_content(socket) do
    contents =
      Content.list_contents()
      |> Repo.preload(:classification)

    assign(socket, :contents, contents)
  end

  defp load_stats(socket) do
    # Get total content count
    total_content =
      from(c in Content.Content, select: count(c.id))
      |> Repo.one() || 0

    # Get classified and unclassified counts
    classified_count =
      from(c in Content.Content, where: c.classified == true, select: count(c.id))
      |> Repo.one() || 0

    unclassified_count = total_content - classified_count

    # Get average confidence from classifications
    avg_confidence =
      from(cl in Intelligence.Classification, select: avg(cl.confidence))
      |> Repo.one()

    # Get sentiment distribution
    sentiment_dist =
      from(cl in Intelligence.Classification,
        group_by: cl.sentiment,
        select: {cl.sentiment, count(cl.id)}
      )
      |> Repo.all()
      |> Enum.into(%{})

    stats = %{
      total_content: total_content,
      classified_count: classified_count,
      unclassified_count: unclassified_count,
      avg_confidence: avg_confidence,
      sentiment_dist: %{
        positive: Map.get(sentiment_dist, "positive", 0),
        negative: Map.get(sentiment_dist, "negative", 0),
        neutral: Map.get(sentiment_dist, "neutral", 0)
      }
    }

    assign(socket, :stats, stats)
  end

  defp truncate_text(nil, _length), do: "No content"

  defp truncate_text(text, length) do
    if String.length(text) <= length do
      text
    else
      String.slice(text, 0, length) <> "..."
    end
  end

  defp format_datetime(nil), do: "Unknown"

  defp format_datetime(%DateTime{} = dt) do
    Calendar.strftime(dt, "%b %d, %Y %I:%M %p")
  end

  defp format_confidence(nil), do: "N/A"

  defp format_confidence(confidence) when is_float(confidence) do
    "#{round(confidence * 100)}%"
  end

  defp format_confidence(_), do: "N/A"

  defp format_percentage(_count, 0), do: "0%"

  defp format_percentage(count, total) do
    percentage = (count / total * 100) |> round()
    "#{percentage}%"
  end
end
