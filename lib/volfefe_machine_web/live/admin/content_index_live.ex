defmodule VolfefeMachineWeb.Admin.ContentIndexLive do
  @moduledoc """
  Admin interface for viewing content and classification data.

  Provides real-time monitoring of ingested content from external sources
  and their associated ML-based sentiment classifications.
  """
  use VolfefeMachineWeb, :live_view

  alias VolfefeMachine.{Content, Intelligence, MarketData, Repo}
  import Ecto.Query

  @impl true
  def mount(_params, _session, socket) do
    # Subscribe to content updates for real-time refresh
    if connected?(socket) do
      Phoenix.PubSub.subscribe(VolfefeMachine.PubSub, "content:updates")
    end

    {:ok,
     socket
     |> assign(:page_title, "Content & Classifications")
     |> assign(:filter_sentiment, "all")
     |> assign(:filter_status, "all")
     |> assign(:sort_by, "published_at")
     |> assign(:sort_order, "desc")
     |> assign(:loading, false)
     |> assign(:error, nil)
     |> assign(:selected_content, nil)
     |> load_content()
     |> load_stats()}
  end

  @impl true
  def handle_params(params, _uri, socket) do
    {:noreply, apply_action(socket, socket.assigns.live_action, params)}
  end

  defp apply_action(socket, :index, _params) do
    assign(socket, :selected_content, nil)
  end

  defp apply_action(socket, :show, %{"id" => id}) do
    content =
      from(c in Content.Content, where: c.id == ^id)
      |> Repo.one()
      |> Repo.preload([:classification, :model_classifications])

    assign(socket, :selected_content, content)
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

      <!-- Filters -->
      <div class="bg-white border rounded-lg p-4 shadow-sm mb-6">
        <div class="flex flex-wrap gap-4">
          <form phx-change="filter_sentiment">
            <label class="block text-sm font-medium text-gray-700 mb-2">
              Sentiment
            </label>
            <select
              name="sentiment"
              class="block w-full pl-3 pr-10 py-2 text-base border-gray-300 focus:outline-none focus:ring-purple-500 focus:border-purple-500 sm:text-sm rounded-md"
            >
              <option value="all" selected={@filter_sentiment == "all"}>All Sentiments</option>
              <option value="positive" selected={@filter_sentiment == "positive"}>Positive</option>
              <option value="negative" selected={@filter_sentiment == "negative"}>Negative</option>
              <option value="neutral" selected={@filter_sentiment == "neutral"}>Neutral</option>
            </select>
          </form>

          <form phx-change="filter_status">
            <label class="block text-sm font-medium text-gray-700 mb-2">
              Classification Status
            </label>
            <select
              name="status"
              class="block w-full pl-3 pr-10 py-2 text-base border-gray-300 focus:outline-none focus:ring-purple-500 focus:border-purple-500 sm:text-sm rounded-md"
            >
              <option value="all" selected={@filter_status == "all"}>All Content</option>
              <option value="classified" selected={@filter_status == "classified"}>Classified Only</option>
              <option value="unclassified" selected={@filter_status == "unclassified"}>Unclassified Only</option>
            </select>
          </form>

          <%= if @filter_sentiment != "all" or @filter_status != "all" do %>
            <div class="flex items-end">
              <button
                phx-click="clear_filters"
                class="px-4 py-2 bg-gray-100 text-gray-700 text-sm font-medium rounded-md hover:bg-gray-200 transition-colors"
              >
                Clear Filters
              </button>
            </div>
          <% end %>
        </div>
      </div>

      <%= if @loading do %>
        <div class="bg-white border rounded-lg shadow-sm p-12 text-center">
          <div class="inline-block animate-spin rounded-full h-12 w-12 border-b-2 border-purple-600 mb-4"></div>
          <p class="text-gray-600">Loading content...</p>
        </div>
      <% else %>
        <%= if Enum.empty?(@contents) do %>
          <div class="bg-white border rounded-lg shadow-sm p-12 text-center">
            <svg class="mx-auto h-16 w-16 text-gray-400 mb-4" fill="none" stroke="currentColor" viewBox="0 0 24 24">
              <path stroke-linecap="round" stroke-linejoin="round" stroke-width="2" d="M9 12h6m-6 4h6m2 5H7a2 2 0 01-2-2V5a2 2 0 012-2h5.586a1 1 0 01.707.293l5.414 5.414a1 1 0 01.293.707V19a2 2 0 01-2 2z" />
            </svg>
            <%= if @filter_sentiment != "all" or @filter_status != "all" do %>
              <p class="text-gray-900 text-lg font-medium mb-2">No content matches your filters</p>
              <p class="text-gray-500 text-sm mb-4">
                Try adjusting your filter criteria to see more results
              </p>
              <button
                phx-click="clear_filters"
                class="inline-flex items-center px-4 py-2 bg-purple-600 text-white text-sm font-medium rounded-md hover:bg-purple-700 transition-colors"
              >
                Clear All Filters
              </button>
            <% else %>
              <p class="text-gray-900 text-lg font-medium mb-2">No content yet</p>
              <p class="text-gray-500 text-sm mb-4">
                Content will appear here once ingested from external sources
              </p>
              <div class="text-xs text-gray-400 mt-4">
                Content is automatically fetched and classified in real-time
              </div>
            <% end %>
          </div>
        <% else %>
        <div class="bg-white border rounded-lg shadow-sm overflow-hidden">
          <div class="overflow-x-auto touch-pan-x overscroll-x-contain">
          <table class="min-w-full divide-y divide-gray-200">
            <thead class="bg-gray-50">
              <tr>
                <th
                  phx-click="sort"
                  phx-value-field="author"
                  class="px-4 md:px-6 py-3 text-left text-xs font-medium text-gray-500 uppercase tracking-wider cursor-pointer hover:bg-gray-100 transition-colors"
                  style="min-width: 120px"
                >
                  <div class="flex items-center">
                    Author
                    <%= if @sort_by == "author" do %>
                      <%= if @sort_order == "asc" do %>
                        <svg class="ml-1 w-4 h-4" fill="currentColor" viewBox="0 0 20 20">
                          <path d="M5.293 9.707a1 1 0 010-1.414l4-4a1 1 0 011.414 0l4 4a1 1 0 01-1.414 1.414L11 7.414V15a1 1 0 11-2 0V7.414L6.707 9.707a1 1 0 01-1.414 0z" />
                        </svg>
                      <% else %>
                        <svg class="ml-1 w-4 h-4" fill="currentColor" viewBox="0 0 20 20">
                          <path d="M14.707 10.293a1 1 0 010 1.414l-4 4a1 1 0 01-1.414 0l-4-4a1 1 0 111.414-1.414L9 12.586V5a1 1 0 012 0v7.586l2.293-2.293a1 1 0 011.414 0z" />
                        </svg>
                      <% end %>
                    <% end %>
                  </div>
                </th>
                <th class="px-4 md:px-6 py-3 text-left text-xs font-medium text-gray-500 uppercase tracking-wider" style="min-width: 200px">
                  Content
                </th>
                <th
                  phx-click="sort"
                  phx-value-field="published_at"
                  class="px-4 md:px-6 py-3 text-left text-xs font-medium text-gray-500 uppercase tracking-wider cursor-pointer hover:bg-gray-100 transition-colors"
                  style="min-width: 140px"
                >
                  <div class="flex items-center">
                    Published
                    <%= if @sort_by == "published_at" do %>
                      <%= if @sort_order == "asc" do %>
                        <svg class="ml-1 w-4 h-4" fill="currentColor" viewBox="0 0 20 20">
                          <path d="M5.293 9.707a1 1 0 010-1.414l4-4a1 1 0 011.414 0l4 4a1 1 0 01-1.414 1.414L11 7.414V15a1 1 0 11-2 0V7.414L6.707 9.707a1 1 0 01-1.414 0z" />
                        </svg>
                      <% else %>
                        <svg class="ml-1 w-4 h-4" fill="currentColor" viewBox="0 0 20 20">
                          <path d="M14.707 10.293a1 1 0 010 1.414l-4 4a1 1 0 01-1.414 0l-4-4a1 1 0 111.414-1.414L9 12.586V5a1 1 0 012 0v7.586l2.293-2.293a1 1 0 011.414 0z" />
                        </svg>
                      <% end %>
                    <% end %>
                  </div>
                </th>
                <th class="px-4 md:px-6 py-3 text-left text-xs font-medium text-gray-500 uppercase tracking-wider" style="min-width: 110px">
                  Sentiment
                </th>
                <th class="px-4 md:px-6 py-3 text-left text-xs font-medium text-gray-500 uppercase tracking-wider" style="min-width: 140px">
                  Confidence
                </th>
                <th class="px-4 md:px-6 py-3 text-left text-xs font-medium text-gray-500 uppercase tracking-wider" style="min-width: 120px">
                  Entities
                </th>
                <th class="px-4 md:px-6 py-3 text-left text-xs font-medium text-gray-500 uppercase tracking-wider" style="min-width: 120px">
                  Market Impact
                </th>
                <th class="px-4 md:px-6 py-3 text-left text-xs font-medium text-gray-500 uppercase tracking-wider" style="min-width: 100px">
                  Status
                </th>
              </tr>
            </thead>
            <tbody class="bg-white divide-y divide-gray-200">
              <%= for content <- @contents do %>
                <tr
                  class="hover:bg-gray-50 transition-colors animate-fade-in cursor-pointer"
                  phx-click="select_content"
                  phx-value-id={content.id}
                >
                  <td class="px-4 md:px-6 py-3 md:py-4 whitespace-nowrap">
                    <div class="text-sm font-medium text-gray-900">
                      <%= content.author || "Unknown" %>
                    </div>
                  </td>
                  <td class="px-4 md:px-6 py-3 md:py-4">
                    <div class="text-sm text-gray-900">
                      <%= truncate_text(content.text, 150) %>
                    </div>
                  </td>
                  <td class="px-4 md:px-6 py-3 md:py-4 whitespace-nowrap">
                    <div class="text-sm text-gray-500">
                      <%= format_datetime(content.published_at) %>
                    </div>
                  </td>
                  <td class="px-4 md:px-6 py-3 md:py-4 whitespace-nowrap">
                    <%= if content.classification do %>
                      <%= render_sentiment_badge(content.classification.sentiment) %>
                    <% else %>
                      <span class="text-xs text-gray-400">-</span>
                    <% end %>
                  </td>
                  <td class="px-4 md:px-6 py-3 md:py-4 whitespace-nowrap">
                    <%= if content.classification do %>
                      <div class="flex items-center">
                        <span class="text-sm font-medium text-gray-900">
                          <%= format_confidence(content.classification.confidence) %>
                        </span>
                        <div class="ml-2 w-12 md:w-16 bg-gray-200 rounded-full h-2">
                          <div
                            class="bg-purple-600 h-2 rounded-full"
                            style={"width: #{round((content.classification.confidence || 0) * 100)}%"}>
                          </div>
                        </div>
                      </div>
                    <% else %>
                      <span class="text-xs text-gray-400">-</span>
                    <% end %>
                  </td>
                  <td class="px-4 md:px-6 py-3 md:py-4 whitespace-nowrap">
                    <%= render_entity_badges(content) %>
                  </td>
                  <td class="px-4 md:px-6 py-3 md:py-4 whitespace-nowrap">
                    <%= render_impact_badge(content) %>
                  </td>
                  <td class="px-4 md:px-6 py-3 md:py-4 whitespace-nowrap">
                    <%= if content.classified do %>
                      <span class="px-2 py-1 text-xs bg-green-100 text-green-800 rounded font-medium">
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
        </div>
        <% end %>
      <% end %>

      <!-- Error Message -->
      <%= if @error do %>
        <div class="mt-4 bg-red-50 border border-red-200 rounded-lg p-4">
          <div class="flex">
            <div class="flex-shrink-0">
              <svg class="h-5 w-5 text-red-400" fill="currentColor" viewBox="0 0 20 20">
                <path fill-rule="evenodd" d="M10 18a8 8 0 100-16 8 8 0 000 16zM8.707 7.293a1 1 0 00-1.414 1.414L8.586 10l-1.293 1.293a1 1 0 101.414 1.414L10 11.414l1.293 1.293a1 1 0 001.414-1.414L11.414 10l1.293-1.293a1 1 0 00-1.414-1.414L10 8.586 8.707 7.293z" clip-rule="evenodd" />
              </svg>
            </div>
            <div class="ml-3">
              <h3 class="text-sm font-medium text-red-800">Error loading content</h3>
              <div class="mt-2 text-sm text-red-700"><%= @error %></div>
            </div>
          </div>
        </div>
      <% end %>

      <!-- Slide-over Detail View -->
      <%= if @selected_content do %>
        <div phx-window-keydown="close_detail" phx-key="Escape">
          <!-- Overlay -->
          <div
            class="fixed inset-0 bg-gray-500/75 transition-opacity z-40"
            phx-click="close_detail"
          >
          </div>

          <!-- Slide-over Panel -->
          <div class="fixed top-0 right-0 h-dvh w-full sm:w-2/3 lg:w-1/2 xl:w-2/5 bg-white shadow-xl z-50 overflow-y-auto">
            <div class="p-6 space-y-6">
              <!-- Header with Close Button -->
              <div class="flex justify-between items-start">
                <h2 class="text-xl font-bold text-gray-900">Content Details</h2>
                <button
                  phx-click="close_detail"
                  class="text-gray-400 hover:text-gray-500 focus:outline-none"
                >
                  <svg class="h-6 w-6" fill="none" stroke="currentColor" viewBox="0 0 24 24">
                    <path stroke-linecap="round" stroke-linejoin="round" stroke-width="2" d="M6 18L18 6M6 6l12 12" />
                  </svg>
                </button>
              </div>

              <!-- Content Information -->
              <div>
                <h3 class="text-sm font-semibold text-gray-900 uppercase tracking-wider flex items-center gap-2 mb-3">
                  <svg class="h-5 w-5 text-purple-600" fill="none" stroke="currentColor" viewBox="0 0 24 24">
                    <path stroke-linecap="round" stroke-linejoin="round" stroke-width="2" d="M9 12h6m-6 4h6m2 5H7a2 2 0 01-2-2V5a2 2 0 012-2h5.586a1 1 0 01.707.293l5.414 5.414a1 1 0 01.293.707V19a2 2 0 01-2 2z" />
                  </svg>
                  Content Information
                </h3>
                <div class="bg-gray-50 rounded-lg p-4 border border-gray-200 space-y-2">
                  <div class="grid grid-cols-3 gap-2">
                    <span class="text-sm font-medium text-gray-500">Author:</span>
                    <span class="col-span-2 text-sm text-gray-900"><%= @selected_content.author || "Unknown" %></span>
                  </div>
                  <div class="grid grid-cols-3 gap-2">
                    <span class="text-sm font-medium text-gray-500">Published:</span>
                    <span class="col-span-2 text-sm text-gray-900"><%= format_datetime(@selected_content.published_at) %></span>
                  </div>
                  <div class="grid grid-cols-3 gap-2">
                    <span class="text-sm font-medium text-gray-500">External ID:</span>
                    <span class="col-span-2 text-sm text-gray-900 font-mono text-xs break-all"><%= @selected_content.external_id %></span>
                  </div>
                  <%= if @selected_content.url do %>
                    <div class="grid grid-cols-3 gap-2">
                      <span class="text-sm font-medium text-gray-500">URL:</span>
                      <span class="col-span-2 text-sm">
                        <a href={@selected_content.url} target="_blank" class="text-purple-600 hover:text-purple-700 underline">
                          View Original →
                        </a>
                      </span>
                    </div>
                  <% end %>
                </div>
              </div>

              <!-- Full Text -->
              <div>
                <h3 class="text-sm font-semibold text-gray-900 uppercase tracking-wider flex items-center gap-2 mb-3">
                  <svg class="h-5 w-5 text-purple-600" fill="none" stroke="currentColor" viewBox="0 0 24 24">
                    <path stroke-linecap="round" stroke-linejoin="round" stroke-width="2" d="M9 12h6m-6 4h6m2 5H7a2 2 0 01-2-2V5a2 2 0 012-2h5.586a1 1 0 01.707.293l5.414 5.414a1 1 0 01.293.707V19a2 2 0 01-2 2z" />
                  </svg>
                  Full Text
                </h3>
                <div class="bg-gray-50 rounded-lg p-4 border border-gray-200">
                  <p class="text-sm text-gray-900 whitespace-pre-wrap leading-relaxed"><%= @selected_content.text %></p>
                  <div class="mt-3 text-xs text-gray-500">
                    <%= String.length(@selected_content.text || "") %> characters
                  </div>
                </div>
              </div>

              <!-- Classification Results -->
              <%= if @selected_content.classification do %>
                <div>
                  <h3 class="text-sm font-semibold text-gray-900 uppercase tracking-wider flex items-center gap-2 mb-3">
                    <svg class="h-5 w-5 text-purple-600" fill="none" stroke="currentColor" viewBox="0 0 24 24">
                      <path stroke-linecap="round" stroke-linejoin="round" stroke-width="2" d="M9 5H7a2 2 0 00-2 2v12a2 2 0 002 2h10a2 2 0 002-2V7a2 2 0 00-2-2h-2M9 5a2 2 0 002 2h2a2 2 0 002-2M9 5a2 2 0 012-2h2a2 2 0 012 2m-6 9l2 2 4-4" />
                    </svg>
                    Classification Results
                  </h3>
                  <div class="bg-gray-50 rounded-lg p-4 border border-gray-200 space-y-3">
                    <div class="flex items-center justify-between">
                      <span class="text-sm font-medium text-gray-500">Sentiment:</span>
                      <%= render_sentiment_badge(@selected_content.classification.sentiment) %>
                    </div>
                    <div>
                      <div class="flex items-center justify-between mb-2">
                        <span class="text-sm font-medium text-gray-500">Confidence:</span>
                        <span class="text-sm font-bold text-gray-900">
                          <%= format_confidence(@selected_content.classification.confidence) %>
                        </span>
                      </div>
                      <div class="w-full bg-gray-200 rounded-full h-3">
                        <div
                          class="bg-purple-600 h-3 rounded-full transition-all"
                          style={"width: #{round((@selected_content.classification.confidence || 0) * 100)}%"}
                        >
                        </div>
                      </div>
                    </div>
                    <div class="grid grid-cols-2 gap-2 text-xs">
                      <div>
                        <span class="text-gray-500">Model:</span>
                        <span class="text-gray-900 ml-1"><%= @selected_content.classification.model_version || "N/A" %></span>
                      </div>
                    </div>
                  </div>
                </div>
              <% else %>
                <div>
                  <h3 class="text-sm font-semibold text-gray-900 uppercase tracking-wider flex items-center gap-2 mb-3">
                    <svg class="h-5 w-5 text-gray-400" fill="none" stroke="currentColor" viewBox="0 0 24 24">
                      <path stroke-linecap="round" stroke-linejoin="round" stroke-width="2" d="M12 8v4l3 3m6-3a9 9 0 11-18 0 9 9 0 0118 0z" />
                    </svg>
                    Classification Pending
                  </h3>
                  <div class="bg-gray-50 rounded-lg p-4 border border-gray-200">
                    <p class="text-sm text-gray-500">This content has not been classified yet.</p>
                  </div>
                </div>
              <% end %>

              <!-- Market Impact Timeline -->
              <%= render_market_impact_timeline(@selected_content, @selected_content.id) %>

              <!-- Model Comparison -->
              <%= if length(@selected_content.model_classifications) > 0 do %>
                <div>
                  <h3 class="text-sm font-semibold text-gray-900 uppercase tracking-wider flex items-center gap-2 mb-3">
                    <svg class="h-5 w-5 text-purple-600" fill="none" stroke="currentColor" viewBox="0 0 24 24">
                      <path stroke-linecap="round" stroke-linejoin="round" stroke-width="2" d="M9 19v-6a2 2 0 00-2-2H5a2 2 0 00-2 2v6a2 2 0 002 2h2a2 2 0 002-2zm0 0V9a2 2 0 012-2h2a2 2 0 012 2v10m-6 0a2 2 0 002 2h2a2 2 0 002-2m0 0V5a2 2 0 012-2h2a2 2 0 012 2v14a2 2 0 01-2 2h-2a2 2 0 01-2-2z" />
                    </svg>
                    Model Comparison
                    <span class="ml-2 px-2 py-0.5 bg-purple-100 text-purple-700 text-xs rounded font-medium">
                      <%= length(@selected_content.model_classifications) %> Models
                    </span>
                  </h3>
                  <div class="space-y-3">
                    <%= for model_class <- sort_model_classifications(@selected_content.model_classifications, @selected_content.classification) do %>
                      <%= render_model_card(assigns, model_class, is_primary_model?(model_class, @selected_content.classification)) %>
                    <% end %>

                    <%= if length(@selected_content.model_classifications) > 1 do %>
                      <%= render_consensus_summary(assigns, @selected_content.model_classifications) %>
                    <% end %>
                  </div>
                </div>
              <% end %>

              <!-- Metadata -->
              <%= if @selected_content.meta && map_size(@selected_content.meta) > 0 do %>
                <div>
                  <h3 class="text-sm font-semibold text-gray-900 uppercase tracking-wider flex items-center gap-2 mb-3">
                    <svg class="h-5 w-5 text-purple-600" fill="none" stroke="currentColor" viewBox="0 0 24 24">
                      <path stroke-linecap="round" stroke-linejoin="round" stroke-width="2" d="M7 7h.01M7 3h5c.512 0 1.024.195 1.414.586l7 7a2 2 0 010 2.828l-7 7a2 2 0 01-2.828 0l-7-7A1.994 1.994 0 013 12V7a4 4 0 014-4z" />
                    </svg>
                    Metadata
                  </h3>
                  <div class="bg-gray-50 rounded-lg p-4 border border-gray-200">
                    <pre class="text-xs text-gray-900 overflow-x-auto"><%= Jason.encode!(@selected_content.meta, pretty: true) %></pre>
                  </div>
                </div>
              <% end %>

              <!-- Extracted Entities Section -->
              <%= render_entity_details(@selected_content) %>

              <!-- Future Features Placeholder -->
              <div class="opacity-60">
                <h3 class="text-sm font-semibold text-gray-900 uppercase tracking-wider flex items-center gap-2 mb-3">
                  <svg class="h-5 w-5 text-gray-400" fill="none" stroke="currentColor" viewBox="0 0 24 24">
                    <path stroke-linecap="round" stroke-linejoin="round" stroke-width="2" d="M13 10V3L4 14h7v7l9-11h-7z" />
                  </svg>
                  Future Features
                  <span class="ml-2 px-2 py-0.5 bg-gray-200 text-gray-600 text-xs rounded">Coming Soon</span>
                </h3>
                <div class="bg-gray-50 rounded-lg p-4 border border-gray-200 space-y-4">
                  <div>
                    <h4 class="text-xs font-semibold text-gray-700 mb-2">📈 Trading Signals</h4>
                    <ul class="text-xs text-gray-500 space-y-1">
                      <li>• Strategy: [Not yet implemented]</li>
                      <li>• Signals: [Pending]</li>
                      <li>• Risk Level: [Pending]</li>
                    </ul>
                  </div>
                  <div>
                    <h4 class="text-xs font-semibold text-gray-700 mb-2">🔗 Related Content</h4>
                    <ul class="text-xs text-gray-500 space-y-1">
                      <li>• Similar posts: [Coming soon]</li>
                      <li>• By same author: [Coming soon]</li>
                    </ul>
                  </div>
                </div>
              </div>

              <!-- Close Button (Bottom) -->
              <div class="flex justify-end pt-4 border-t border-gray-200">
                <button
                  phx-click="close_detail"
                  class="px-4 py-2 bg-gray-100 text-gray-700 text-sm font-medium rounded-md hover:bg-gray-200 transition-colors"
                >
                  Close
                </button>
              </div>
            </div>
          </div>
        </div>
      <% end %>
    </div>
    """
  end

  # ========================================
  # PubSub Handlers
  # ========================================

  @impl true
  def handle_info({:content_classified, _content_id}, socket) do
    {:noreply,
     socket
     |> load_content()
     |> load_stats()}
  end

  @impl true
  def handle_info({:content_created, _content_id}, socket) do
    {:noreply,
     socket
     |> load_content()
     |> load_stats()}
  end

  # ========================================
  # Event Handlers
  # ========================================

  @impl true
  def handle_event("filter_sentiment", %{"sentiment" => sentiment}, socket) do
    {:noreply,
     socket
     |> assign(:filter_sentiment, sentiment)
     |> load_content()}
  end

  @impl true
  def handle_event("filter_status", %{"status" => status}, socket) do
    {:noreply,
     socket
     |> assign(:filter_status, status)
     |> load_content()}
  end

  @impl true
  def handle_event("clear_filters", _params, socket) do
    {:noreply,
     socket
     |> assign(:filter_sentiment, "all")
     |> assign(:filter_status, "all")
     |> load_content()}
  end

  @impl true
  def handle_event("sort", %{"field" => field}, socket) do
    sort_order =
      if socket.assigns.sort_by == field and socket.assigns.sort_order == "desc" do
        "asc"
      else
        "desc"
      end

    {:noreply,
     socket
     |> assign(:sort_by, field)
     |> assign(:sort_order, sort_order)
     |> load_content()}
  end

  @impl true
  def handle_event("select_content", %{"id" => id}, socket) do
    {:noreply, push_patch(socket, to: ~p"/admin/content/#{id}")}
  end

  @impl true
  def handle_event("close_detail", _params, socket) do
    {:noreply, push_patch(socket, to: ~p"/admin/content")}
  end

  # ========================================
  # Private Functions
  # ========================================

  defp load_content(socket) do
    try do
      query = from(c in Content.Content)

      # Apply status filter
      query =
        case socket.assigns.filter_status do
          "classified" -> where(query, [c], c.classified == true)
          "unclassified" -> where(query, [c], c.classified == false)
          _ -> query
        end

      # Apply sentiment filter (requires join with classifications)
      query =
        case socket.assigns.filter_sentiment do
          sentiment when sentiment in ["positive", "negative", "neutral"] ->
            query
            |> join(:inner, [c], cl in assoc(c, :classification))
            |> where([c, cl], cl.sentiment == ^sentiment)

          _ ->
            query
        end

      # Apply sorting
      query =
        case {socket.assigns.sort_by, socket.assigns.sort_order} do
          {"author", "asc"} -> order_by(query, [c], asc: c.author)
          {"author", "desc"} -> order_by(query, [c], desc: c.author)
          {"published_at", "asc"} -> order_by(query, [c], asc: c.published_at)
          {"published_at", "desc"} -> order_by(query, [c], desc: c.published_at)
          _ -> order_by(query, [c], desc: c.published_at)
        end

      contents =
        query
        |> Repo.all()
        |> Repo.preload(:classification)

      socket
      |> assign(:contents, contents)
      |> assign(:error, nil)
    rescue
      error ->
        socket
        |> assign(:contents, [])
        |> assign(:error, "Failed to load content: #{Exception.message(error)}")
    end
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

  defp render_sentiment_badge(sentiment) do
    case sentiment do
      "positive" ->
        assigns = %{}
        ~H"""
        <span class="inline-flex items-center px-2.5 py-0.5 rounded-full text-xs font-medium bg-green-100 text-green-800">
          <svg class="w-3 h-3 mr-1" fill="currentColor" viewBox="0 0 20 20">
            <path fill-rule="evenodd" d="M10 18a8 8 0 100-16 8 8 0 000 16zm3.707-9.293a1 1 0 00-1.414-1.414L9 10.586 7.707 9.293a1 1 0 00-1.414 1.414l2 2a1 1 0 001.414 0l4-4z" clip-rule="evenodd" />
          </svg>
          Positive
        </span>
        """

      "negative" ->
        assigns = %{}
        ~H"""
        <span class="inline-flex items-center px-2.5 py-0.5 rounded-full text-xs font-medium bg-red-100 text-red-800">
          <svg class="w-3 h-3 mr-1" fill="currentColor" viewBox="0 0 20 20">
            <path fill-rule="evenodd" d="M10 18a8 8 0 100-16 8 8 0 000 16zM8.707 7.293a1 1 0 00-1.414 1.414L8.586 10l-1.293 1.293a1 1 0 101.414 1.414L10 11.414l1.293 1.293a1 1 0 001.414-1.414L11.414 10l1.293-1.293a1 1 0 00-1.414-1.414L10 8.586 8.707 7.293z" clip-rule="evenodd" />
          </svg>
          Negative
        </span>
        """

      "neutral" ->
        assigns = %{}
        ~H"""
        <span class="inline-flex items-center px-2.5 py-0.5 rounded-full text-xs font-medium bg-gray-100 text-gray-800">
          <svg class="w-3 h-3 mr-1" fill="currentColor" viewBox="0 0 20 20">
            <path fill-rule="evenodd" d="M10 18a8 8 0 100-16 8 8 0 000 16zm0-2a6 6 0 100-12 6 6 0 000 12z" clip-rule="evenodd" />
          </svg>
          Neutral
        </span>
        """

      _ ->
        assigns = %{}
        ~H"""
        <span class="text-xs text-gray-400">Unknown</span>
        """
    end
  end

  # ========================================
  # Model Comparison Functions
  # ========================================

  defp sort_model_classifications(model_classifications, primary_classification) do
    Enum.sort_by(model_classifications, fn mc ->
      # Primary model first, then by confidence descending
      is_primary = is_primary_model?(mc, primary_classification)
      {!is_primary, -mc.confidence}
    end)
  end

  defp is_primary_model?(_model_class, nil), do: false

  defp is_primary_model?(model_class, primary_classification) do
    # Check if primary classification is a consensus (contains "consensus")
    # If so, extract the primary model from meta
    cond do
      # Direct model_version match (for single-model classifications)
      model_class.model_version == primary_classification.model_version ->
        true

      # For consensus classifications, check if this model had highest vote
      String.contains?(primary_classification.model_version || "", "consensus") ->
        is_consensus_winner?(model_class, primary_classification)

      true ->
        false
    end
  end

  defp is_consensus_winner?(model_class, primary_classification) do
    # Extract model votes from consensus meta
    model_votes = get_in(primary_classification.meta, ["model_votes"]) || []

    # Find the model with highest weighted score
    winner = Enum.max_by(model_votes, fn vote ->
      vote["weighted_score"] || 0
    end, fn -> nil end)

    # Check if this model is the winner
    winner && winner["model_id"] == model_class.model_id
  end

  defp render_model_card(assigns, model_class, is_primary) do
    consensus_sentiment = if assigns.selected_content.classification do
      assigns.selected_content.classification.sentiment
    else
      nil
    end

    disagrees = consensus_sentiment && model_class.sentiment != consensus_sentiment
    is_ambiguous = model_class.confidence < 0.6

    quality_flags = get_in(model_class.meta, ["quality", "flags"]) || []
    latency_ms = get_in(model_class.meta, ["processing", "latency_ms"])

    assigns = Map.merge(assigns, %{
      model_class: model_class,
      is_primary: is_primary,
      disagrees: disagrees,
      is_ambiguous: is_ambiguous,
      quality_flags: quality_flags,
      latency_ms: latency_ms
    })

    ~H"""
    <div class={"border rounded-lg #{if @is_primary, do: "border-blue-300 bg-blue-50", else: "border-gray-200 bg-gray-50"} p-3"}>
      <div class="flex items-start justify-between mb-2">
        <div class="flex items-center gap-2">
          <h4 class="text-sm font-semibold text-gray-900">
            <%= format_model_name(@model_class.model_id) %>
          </h4>
          <%= if @is_primary do %>
            <span class="inline-flex items-center px-2 py-0.5 rounded text-xs font-medium bg-blue-600 text-white">
              <svg class="w-3 h-3 mr-1" fill="currentColor" viewBox="0 0 20 20">
                <path fill-rule="evenodd" d="M10 18a8 8 0 100-16 8 8 0 000 16zm3.707-9.293a1 1 0 00-1.414-1.414L9 10.586 7.707 9.293a1 1 0 00-1.414 1.414l2 2a1 1 0 001.414 0l4-4z" clip-rule="evenodd" />
              </svg>
              Primary
            </span>
          <% end %>
          <%= if @disagrees do %>
            <span class="inline-flex items-center px-2 py-0.5 rounded text-xs font-medium bg-amber-100 text-amber-800">
              ⚠️ Disagrees
            </span>
          <% end %>
          <%= if @is_ambiguous do %>
            <span class="inline-flex items-center px-2 py-0.5 rounded text-xs font-medium bg-yellow-100 text-yellow-800">
              ⚠️ Ambiguous
            </span>
          <% end %>
        </div>
      </div>

      <div class="space-y-2">
        <div class="flex items-center justify-between">
          <span class="text-xs text-gray-600">Sentiment:</span>
          <%= render_sentiment_badge(@model_class.sentiment) %>
        </div>

        <div>
          <div class="flex items-center justify-between mb-1">
            <span class="text-xs text-gray-600">Confidence:</span>
            <span class="text-sm font-bold text-gray-900">
              <%= format_confidence(@model_class.confidence) %>
            </span>
          </div>
          <div class="w-full bg-gray-200 rounded-full h-2">
            <div
              class={"h-2 rounded-full transition-all #{confidence_color(@model_class.confidence)}"}
              style={"width: #{round(@model_class.confidence * 100)}%"}
            >
            </div>
          </div>
        </div>

        <%= if length(@quality_flags) > 0 do %>
          <div class="flex flex-wrap gap-1">
            <%= for flag <- @quality_flags do %>
              <span class="text-xs px-2 py-0.5 bg-purple-100 text-purple-700 rounded">
                <%= format_quality_flag(flag) %>
              </span>
            <% end %>
          </div>
        <% end %>

        <%= if @latency_ms do %>
          <div class="text-xs text-gray-500">
            Processing: <%= format_latency(@latency_ms) %>
          </div>
        <% end %>

        <details class="mt-2">
          <summary class="text-xs text-purple-600 cursor-pointer hover:text-purple-700 font-medium">
            View Details ▼
          </summary>
          <div class="mt-2 pt-2 border-t border-gray-300 space-y-2">
            <%= if @model_class.meta["raw_scores"] do %>
              <div>
                <div class="text-xs font-medium text-gray-700 mb-1">Raw Scores:</div>
                <div class="text-xs text-gray-600 space-y-0.5">
                  <%= for {sentiment, score} <- @model_class.meta["raw_scores"] do %>
                    <div class="flex justify-between">
                      <span class="capitalize"><%= sentiment %>:</span>
                      <span class="font-mono"><%= Float.round(score, 4) %></span>
                    </div>
                  <% end %>
                </div>
              </div>
            <% end %>

            <%= if @model_class.meta["quality"] do %>
              <div>
                <div class="text-xs font-medium text-gray-700 mb-1">Quality Metrics:</div>
                <div class="text-xs text-gray-600 space-y-0.5">
                  <%= if @model_class.meta["quality"]["entropy"] do %>
                    <div class="flex justify-between">
                      <span>Entropy:</span>
                      <span class="font-mono"><%= Float.round(@model_class.meta["quality"]["entropy"], 4) %></span>
                    </div>
                  <% end %>
                  <%= if @model_class.meta["quality"]["score_margin"] do %>
                    <div class="flex justify-between">
                      <span>Score Margin:</span>
                      <span class="font-mono"><%= Float.round(@model_class.meta["quality"]["score_margin"], 4) %></span>
                    </div>
                  <% end %>
                </div>
              </div>
            <% end %>

            <div>
              <div class="text-xs font-medium text-gray-700 mb-1">Model Info:</div>
              <div class="text-xs text-gray-600">
                <div class="font-mono text-xs break-all"><%= @model_class.model_version %></div>
              </div>
            </div>
          </div>
        </details>
      </div>
    </div>
    """
  end

  defp render_consensus_summary(assigns, model_classifications) do
    sentiments = Enum.map(model_classifications, & &1.sentiment)
    sentiment_counts = Enum.frequencies(sentiments)
    {consensus_sentiment, consensus_count} = Enum.max_by(sentiment_counts, fn {_s, count} -> count end)

    total_models = length(model_classifications)
    agreement_pct = round(consensus_count / total_models * 100)

    disagreeing_models = Enum.filter(model_classifications, fn mc ->
      mc.sentiment != consensus_sentiment
    end)

    confidence_values = Enum.map(model_classifications, & &1.confidence)
    min_confidence = Enum.min(confidence_values)
    max_confidence = Enum.max(confidence_values)

    assigns = Map.merge(assigns, %{
      consensus_sentiment: consensus_sentiment,
      consensus_count: consensus_count,
      total_models: total_models,
      agreement_pct: agreement_pct,
      disagreeing_models: disagreeing_models,
      min_confidence: min_confidence,
      max_confidence: max_confidence
    })

    ~H"""
    <div class="border-t border-gray-300 pt-3 mt-3">
      <h4 class="text-xs font-semibold text-gray-900 uppercase tracking-wider mb-2">
        📊 Consensus Summary
      </h4>
      <div class="bg-white rounded-lg p-3 border border-gray-200 space-y-2">
        <div class="flex items-center justify-between">
          <span class="text-xs text-gray-600">Agreement:</span>
          <div class="flex items-center gap-2">
            <span class="text-sm font-bold text-gray-900">
              <%= @consensus_count %>/<%= @total_models %> models (<%= @agreement_pct %>%)
            </span>
            <%= if @agreement_pct == 100 do %>
              <span class="text-green-600">✓ Full consensus</span>
            <% else %>
              <span class="text-amber-600">⚠️ Partial agreement</span>
            <% end %>
          </div>
        </div>

        <div class="flex items-center justify-between">
          <span class="text-xs text-gray-600">Consensus Sentiment:</span>
          <%= render_sentiment_badge(@consensus_sentiment) %>
        </div>

        <div class="flex items-center justify-between">
          <span class="text-xs text-gray-600">Confidence Range:</span>
          <span class="text-xs text-gray-900">
            <%= format_confidence(@min_confidence) %> - <%= format_confidence(@max_confidence) %>
          </span>
        </div>

        <%= if length(@disagreeing_models) > 0 do %>
          <div class="pt-2 border-t border-gray-200">
            <div class="text-xs text-gray-700 font-medium mb-1">
              Disagreeing Models:
            </div>
            <ul class="text-xs text-gray-600 space-y-1">
              <%= for model <- @disagreeing_models do %>
                <li>
                  <span class="font-medium"><%= format_model_name(model.model_id) %></span>:
                  <%= model.sentiment %> (<%= format_confidence(model.confidence) %>)
                </li>
              <% end %>
            </ul>
          </div>
        <% end %>
      </div>
    </div>
    """
  end

  defp format_model_name(model_id) do
    case model_id do
      "finbert" -> "FinBERT"
      "twitter_roberta" -> "Twitter-RoBERTa"
      "distilbert" -> "DistilBERT"
      _ -> String.capitalize(model_id)
    end
  end

  defp confidence_color(confidence) when confidence >= 0.8, do: "bg-green-500"
  defp confidence_color(confidence) when confidence >= 0.6, do: "bg-yellow-500"
  defp confidence_color(_), do: "bg-red-500"

  defp format_quality_flag(flag) do
    flag
    |> String.replace("_", " ")
    |> String.capitalize()
  end

  defp format_latency(ms) when ms < 1000, do: "#{ms}ms"
  defp format_latency(ms), do: "#{Float.round(ms / 1000, 2)}s"

  # ========================================
  # Entity Display Functions
  # ========================================

  defp format_entity_confidence(nil), do: "N/A"
  defp format_entity_confidence(c) when is_number(c), do: "#{Float.round(c, 2)}"
  defp format_entity_confidence(_), do: "N/A"

  defp render_entity_badges(content) do
    entity_counts = Intelligence.get_entity_counts(content.id)

    assigns = %{entity_counts: entity_counts}

    ~H"""
    <%= if @entity_counts.total > 0 do %>
      <div class="flex gap-1 flex-wrap">
        <%= if @entity_counts.org > 0 do %>
          <span class="inline-flex items-center px-2 py-0.5 rounded text-xs font-medium bg-blue-100 text-blue-800" title="Organizations">
            🏢 <%= @entity_counts.org %>
          </span>
        <% end %>
        <%= if @entity_counts.loc > 0 do %>
          <span class="inline-flex items-center px-2 py-0.5 rounded text-xs font-medium bg-green-100 text-green-800" title="Locations">
            📍 <%= @entity_counts.loc %>
          </span>
        <% end %>
        <%= if @entity_counts.per > 0 do %>
          <span class="inline-flex items-center px-2 py-0.5 rounded text-xs font-medium bg-purple-100 text-purple-800" title="People">
            👤 <%= @entity_counts.per %>
          </span>
        <% end %>
        <%= if @entity_counts.misc > 0 do %>
          <span class="inline-flex items-center px-2 py-0.5 rounded text-xs font-medium bg-gray-100 text-gray-800" title="Miscellaneous">
            🔖 <%= @entity_counts.misc %>
          </span>
        <% end %>
      </div>
    <% else %>
      <span class="text-xs text-gray-400">-</span>
    <% end %>
    """
  end

  defp render_entity_details(content) do
    entity_data = Intelligence.get_entity_data(content.id)
    entity_counts = Intelligence.get_entity_counts(content.id)

    assigns = %{entity_data: entity_data, entity_counts: entity_counts}

    ~H"""
    <%= if @entity_data do %>
      <div>
        <h3 class="text-sm font-semibold text-gray-900 uppercase tracking-wider flex items-center gap-2 mb-3">
          <svg class="h-5 w-5 text-blue-500" fill="none" stroke="currentColor" viewBox="0 0 24 24">
            <path stroke-linecap="round" stroke-linejoin="round" stroke-width="2" d="M7 7h.01M7 3h5c.512 0 1.024.195 1.414.586l7 7a2 2 0 010 2.828l-7 7a2 2 0 01-2.828 0l-7-7A1.994 1.994 0 013 12V7a4 4 0 014-4z" />
          </svg>
          Extracted Entities
          <span class="ml-2 px-2 py-0.5 bg-blue-100 text-blue-700 text-xs rounded font-medium">
            <%= @entity_counts.total %> found
          </span>
        </h3>

        <div class="bg-gradient-to-br from-blue-50 to-indigo-50 rounded-lg p-4 border border-blue-200 space-y-3">
          <%= if @entity_counts.org > 0 do %>
            <div class="bg-white rounded-lg p-3 border border-blue-100">
              <h4 class="text-xs font-semibold text-blue-900 mb-2 flex items-center gap-1">
                🏢 Organizations (<%= @entity_counts.org %>)
              </h4>
              <ul class="text-xs text-gray-700 space-y-1">
                <%= for entity <- Enum.filter(@entity_data.extracted, &(&1["type"] == "ORG")) do %>
                  <li class="flex justify-between items-center">
                    <span class="font-medium"><%= entity["text"] %></span>
                    <span class="text-gray-500 text-[10px]"><%= format_entity_confidence(entity["confidence"]) %></span>
                  </li>
                <% end %>
              </ul>
            </div>
          <% end %>

          <%= if @entity_counts.loc > 0 do %>
            <div class="bg-white rounded-lg p-3 border border-green-100">
              <h4 class="text-xs font-semibold text-green-900 mb-2 flex items-center gap-1">
                📍 Locations (<%= @entity_counts.loc %>)
              </h4>
              <ul class="text-xs text-gray-700 space-y-1">
                <%= for entity <- Enum.filter(@entity_data.extracted, &(&1["type"] == "LOC")) do %>
                  <li class="flex justify-between items-center">
                    <span class="font-medium"><%= entity["text"] %></span>
                    <span class="text-gray-500 text-[10px]"><%= format_entity_confidence(entity["confidence"]) %></span>
                  </li>
                <% end %>
              </ul>
            </div>
          <% end %>

          <%= if @entity_counts.per > 0 do %>
            <div class="bg-white rounded-lg p-3 border border-purple-100">
              <h4 class="text-xs font-semibold text-purple-900 mb-2 flex items-center gap-1">
                👤 People (<%= @entity_counts.per %>)
              </h4>
              <ul class="text-xs text-gray-700 space-y-1">
                <%= for entity <- Enum.filter(@entity_data.extracted, &(&1["type"] == "PER")) do %>
                  <li class="flex justify-between items-center">
                    <span class="font-medium"><%= entity["text"] %></span>
                    <span class="text-gray-500 text-[10px]"><%= format_entity_confidence(entity["confidence"]) %></span>
                  </li>
                <% end %>
              </ul>
            </div>
          <% end %>

          <%= if @entity_counts.misc > 0 do %>
            <div class="bg-white rounded-lg p-3 border border-gray-200">
              <h4 class="text-xs font-semibold text-gray-900 mb-2 flex items-center gap-1">
                🔖 Miscellaneous (<%= @entity_counts.misc %>)
              </h4>
              <ul class="text-xs text-gray-700 space-y-1">
                <%= for entity <- Enum.filter(@entity_data.extracted, &(&1["type"] == "MISC")) do %>
                  <li class="flex justify-between items-center">
                    <span class="font-medium"><%= entity["text"] %></span>
                    <span class="text-gray-500 text-[10px]"><%= format_entity_confidence(entity["confidence"]) %></span>
                  </li>
                <% end %>
              </ul>
            </div>
          <% end %>

          <div class="pt-2 border-t border-blue-200 text-xs text-gray-500">
            <p>Model: <%= @entity_data.model_id || "BERT-base-NER" %></p>
          </div>
        </div>
      </div>
    <% else %>
      <div>
        <h3 class="text-sm font-semibold text-gray-900 uppercase tracking-wider flex items-center gap-2 mb-3">
          <svg class="h-5 w-5 text-gray-400" fill="none" stroke="currentColor" viewBox="0 0 24 24">
            <path stroke-linecap="round" stroke-linejoin="round" stroke-width="2" d="M7 7h.01M7 3h5c.512 0 1.024.195 1.414.586l7 7a2 2 0 010 2.828l-7 7a2 2 0 01-2.828 0l-7-7A1.994 1.994 0 013 12V7a4 4 0 014-4z" />
          </svg>
          Extracted Entities
        </h3>
        <div class="bg-gray-50 rounded-lg p-4 border border-gray-200">
          <p class="text-xs text-gray-500">No entities extracted for this content.</p>
        </div>
      </div>
    <% end %>
    """
  end

  # ========================================
  # Market Impact Display Functions
  # ========================================

  defp render_impact_badge(content) do
    case MarketData.get_impact_summary(content.id) do
      {:ok, summary} ->
        render_impact_badge_with_summary(summary)

      {:error, :no_snapshots} ->
        assigns = %{}
        ~H"""
        <span class="text-xs text-gray-400">-</span>
        """
    end
  end

  defp render_market_impact_timeline(content, content_id) do
    case MarketData.get_impact_summary(content.id) do
      {:ok, summary} ->
        render_impact_timeline_section(summary, content_id)

      {:error, :no_snapshots} ->
        assigns = %{content_id: content_id}
        ~H"""
        <div>
          <h3 class="text-sm font-semibold text-gray-900 uppercase tracking-wider flex items-center gap-2 mb-3">
            <svg class="h-5 w-5 text-gray-400" fill="none" stroke="currentColor" viewBox="0 0 24 24">
              <path stroke-linecap="round" stroke-linejoin="round" stroke-width="2" d="M13 7h8m0 0v8m0-8l-8 8-4-4-6 6" />
            </svg>
            Market Impact
          </h3>
          <div class="bg-gray-50 rounded-lg p-4 border border-gray-200">
            <p class="text-sm text-gray-500">No market snapshots captured for this content yet.</p>
            <.link
              navigate={~p"/admin/market-analysis?id=#{@content_id}"}
              class="mt-2 inline-flex items-center text-sm text-orange-600 hover:text-orange-700 font-medium"
            >
              View Market Analysis Page →
            </.link>
          </div>
        </div>
        """
    end
  end

  defp render_impact_timeline_section(summary, content_id) do
    isolation_color =
      cond do
        summary.isolation_score >= 0.7 -> "green"
        summary.isolation_score >= 0.5 -> "yellow"
        true -> "red"
      end

    assigns = %{
      summary: summary,
      isolation_color: isolation_color,
      content_id: content_id
    }

    ~H"""
    <div>
      <h3 class="text-sm font-semibold text-gray-900 uppercase tracking-wider flex items-center gap-2 mb-3">
        <svg class="h-5 w-5 text-orange-600" fill="none" stroke="currentColor" viewBox="0 0 24 24">
          <path stroke-linecap="round" stroke-linejoin="round" stroke-width="2" d="M13 7h8m0 0v8m0-8l-8 8-4-4-6 6" />
        </svg>
        Market Impact Analysis
        <%= render_impact_badge_inline(@summary.significance, @summary.max_z_score) %>
      </h3>

      <div class="bg-gradient-to-br from-orange-50 to-amber-50 rounded-lg p-4 border border-orange-200 space-y-4">
        <!-- Summary Stats -->
        <div class="grid grid-cols-3 gap-3">
          <div class="bg-white rounded-lg p-3 border border-orange-100">
            <div class="text-xs text-gray-500 mb-1">Max Impact</div>
            <div class="text-lg font-bold text-gray-900"><%= Float.round(@summary.max_z_score, 2) %>σ</div>
          </div>
          <div class="bg-white rounded-lg p-3 border border-orange-100">
            <div class="text-xs text-gray-500 mb-1">Isolation</div>
            <div class={"text-lg font-bold #{isolation_text_color(@isolation_color)}"}>
              <%= Float.round(@summary.isolation_score, 2) %>
            </div>
          </div>
          <div class="bg-white rounded-lg p-3 border border-orange-100">
            <div class="text-xs text-gray-500 mb-1">Snapshots</div>
            <div class="text-lg font-bold text-gray-900"><%= @summary.snapshot_count %></div>
          </div>
        </div>

        <!-- Asset Impacts -->
        <div>
          <h4 class="text-xs font-semibold text-gray-900 mb-2">Asset-Specific Impacts</h4>
          <div class="space-y-2">
            <%= for asset <- @summary.assets do %>
              <div class="bg-white rounded-lg p-3 border border-gray-200">
                <div class="flex items-center justify-between mb-2">
                  <div class="flex items-center gap-2">
                    <span class="text-sm font-bold text-gray-900"><%= asset.symbol %></span>
                    <%= render_significance_badge_small(asset.significance) %>
                  </div>
                  <span class="text-xs text-gray-500"><%= asset.window %></span>
                </div>
                <div class="flex items-center justify-between">
                  <span class="text-xs text-gray-600">Z-Score:</span>
                  <span class={"text-sm font-mono font-bold #{z_score_color(asset.max_z_score)}"}>
                    <%= Float.round(asset.max_z_score, 2) %>σ
                  </span>
                </div>
              </div>
            <% end %>
          </div>
        </div>

        <!-- Help Section -->
        <details class="mt-4">
          <summary class="text-xs text-orange-700 cursor-pointer hover:text-orange-800 font-medium flex items-center gap-1">
            <svg class="w-4 h-4" fill="none" stroke="currentColor" viewBox="0 0 24 24">
              <path stroke-linecap="round" stroke-linejoin="round" stroke-width="2" d="M13 16h-1v-4h-1m1-4h.01M21 12a9 9 0 11-18 0 9 9 0 0118 0z" />
            </svg>
            Understanding Market Impact Metrics ▼
          </summary>
          <div class="mt-3 pt-3 border-t border-orange-200 space-y-2 text-xs text-gray-700">
            <div>
              <span class="font-semibold text-gray-900">Z-Score (σ):</span>
              <p class="mt-1 text-gray-600">
                Measures how unusual a price move is compared to historical patterns. Higher absolute values indicate more significant moves.
                <ul class="ml-4 mt-1 space-y-0.5 list-disc">
                  <li><span class="font-medium text-red-700">|z| ≥ 2.0</span>: High significance (95th percentile or higher)</li>
                  <li><span class="font-medium text-yellow-700">1.0 ≤ |z| &lt; 2.0</span>: Moderate significance (68th-95th percentile)</li>
                  <li><span class="font-medium text-gray-600">|z| &lt; 1.0</span>: Normal market noise</li>
                </ul>
              </p>
            </div>
            <div>
              <span class="font-semibold text-gray-900">Isolation Score:</span>
              <p class="mt-1 text-gray-600">
                Indicates measurement quality based on nearby content within ±4 hours.
                <ul class="ml-4 mt-1 space-y-0.5 list-disc">
                  <li><span class="font-medium text-green-700">≥ 0.7</span>: Good isolation (reliable measurement)</li>
                  <li><span class="font-medium text-yellow-700">0.5 - 0.7</span>: Moderate contamination (some noise)</li>
                  <li><span class="font-medium text-red-700">&lt; 0.5</span>: High contamination (less reliable)</li>
                </ul>
              </p>
            </div>
            <div>
              <span class="font-semibold text-gray-900">Time Windows:</span>
              <p class="mt-1 text-gray-600">
                Snapshots captured at:
                <span class="font-mono">before</span> (1hr before posting),
                <span class="font-mono">1hr_after</span>,
                <span class="font-mono">4hr_after</span>, and
                <span class="font-mono">24hr_after</span> posting.
              </p>
            </div>
          </div>
        </details>
      </div>
    </div>
    """
  end

  defp render_impact_badge_inline(significance, max_z_score) do
    z_formatted = Float.round(max_z_score, 2)
    assigns = %{significance: significance, max_z: z_formatted}

    case assigns.significance do
      "high" ->
        ~H"""
        <span class="ml-2 px-2 py-0.5 bg-red-600 text-white text-xs rounded font-medium">
          High Impact (z=<%= @max_z %>)
        </span>
        """
      "moderate" ->
        ~H"""
        <span class="ml-2 px-2 py-0.5 bg-yellow-600 text-white text-xs rounded font-medium">
          Moderate (z=<%= @max_z %>)
        </span>
        """
      "noise" ->
        ~H"""
        <span class="ml-2 px-2 py-0.5 bg-gray-500 text-white text-xs rounded font-medium">
          No Impact (z=<%= @max_z %>)
        </span>
        """
      _ ->
        ~H"""
        <span class="ml-2 px-2 py-0.5 bg-gray-400 text-white text-xs rounded">Unknown</span>
        """
    end
  end

  defp render_significance_badge_small(significance) do
    assigns = %{significance: significance}

    case assigns.significance do
      "high" ->
        ~H"""
        <span class="text-xs px-2 py-0.5 bg-red-100 text-red-800 rounded font-medium">High</span>
        """
      "moderate" ->
        ~H"""
        <span class="text-xs px-2 py-0.5 bg-yellow-100 text-yellow-800 rounded font-medium">Mod</span>
        """
      "noise" ->
        ~H"""
        <span class="text-xs px-2 py-0.5 bg-gray-100 text-gray-600 rounded">Noise</span>
        """
      _ ->
        ~H"""
        <span class="text-xs px-2 py-0.5 bg-gray-100 text-gray-400 rounded">-</span>
        """
    end
  end

  defp isolation_text_color("green"), do: "text-green-600"
  defp isolation_text_color("yellow"), do: "text-yellow-600"
  defp isolation_text_color("red"), do: "text-red-600"
  defp isolation_text_color(_), do: "text-gray-600"

  defp z_score_color(z_score) do
    abs_z = abs(z_score)
    cond do
      abs_z >= 2.0 -> "text-red-600"
      abs_z >= 1.0 -> "text-yellow-600"
      true -> "text-gray-600"
    end
  end

  defp render_impact_badge_with_summary(summary) do
    max_z_formatted = Float.round(summary.max_z_score, 2)
    isolation_formatted = Float.round(summary.isolation_score, 2)

    # Determine isolation color
    isolation_color = cond do
      summary.isolation_score >= 0.7 -> "text-green-600"
      summary.isolation_score >= 0.5 -> "text-yellow-600"
      true -> "text-red-600"
    end

    assigns = %{
      significance: summary.significance,
      max_z_score: max_z_formatted,
      snapshot_count: summary.snapshot_count,
      isolation_score: isolation_formatted,
      isolation_color: isolation_color
    }

    case assigns.significance do
      "high" ->
        ~H"""
        <div class="flex flex-col gap-1">
          <span class="inline-flex items-center px-2.5 py-0.5 rounded-full text-xs font-medium bg-red-100 text-red-800" title={"Max z-score: #{@max_z_score}"}>
            <svg class="w-3 h-3 mr-1" fill="currentColor" viewBox="0 0 20 20">
              <path fill-rule="evenodd" d="M10 18a8 8 0 100-16 8 8 0 000 16zm1-12a1 1 0 10-2 0v4a1 1 0 00.293.707l2.828 2.829a1 1 0 101.415-1.415L11 9.586V6z" clip-rule="evenodd" />
            </svg>
            High Impact
          </span>
          <div class="flex items-center gap-2 text-xs text-gray-500">
            <span title="Snapshot count"><%= @snapshot_count %> snaps</span>
            <span>•</span>
            <span class={"font-medium #{@isolation_color}"} title="Isolation score">iso: <%= @isolation_score %></span>
          </div>
        </div>
        """

      "moderate" ->
        ~H"""
        <div class="flex flex-col gap-1">
          <span class="inline-flex items-center px-2.5 py-0.5 rounded-full text-xs font-medium bg-yellow-100 text-yellow-800" title={"Max z-score: #{@max_z_score}"}>
            <svg class="w-3 h-3 mr-1" fill="currentColor" viewBox="0 0 20 20">
              <path fill-rule="evenodd" d="M10 18a8 8 0 100-16 8 8 0 000 16zm1-12a1 1 0 10-2 0v4a1 1 0 00.293.707l2.828 2.829a1 1 0 101.415-1.415L11 9.586V6z" clip-rule="evenodd" />
            </svg>
            Moderate
          </span>
          <div class="flex items-center gap-2 text-xs text-gray-500">
            <span title="Snapshot count"><%= @snapshot_count %> snaps</span>
            <span>•</span>
            <span class={"font-medium #{@isolation_color}"} title="Isolation score">iso: <%= @isolation_score %></span>
          </div>
        </div>
        """

      "noise" ->
        ~H"""
        <div class="flex flex-col gap-1">
          <span class="inline-flex items-center px-2.5 py-0.5 rounded-full text-xs font-medium bg-gray-100 text-gray-600" title={"Max z-score: #{@max_z_score}"}>
            <svg class="w-3 h-3 mr-1" fill="currentColor" viewBox="0 0 20 20">
              <path fill-rule="evenodd" d="M10 18a8 8 0 100-16 8 8 0 000 16zm0-2a6 6 0 100-12 6 6 0 000 12z" clip-rule="evenodd" />
            </svg>
            No Impact
          </span>
          <div class="flex items-center gap-2 text-xs text-gray-500">
            <span title="Snapshot count"><%= @snapshot_count %> snaps</span>
            <span>•</span>
            <span class={"font-medium #{@isolation_color}"} title="Isolation score">iso: <%= @isolation_score %></span>
          </div>
        </div>
        """

      _ ->
        ~H"""
        <span class="text-xs text-gray-400">Unknown</span>
        """
    end
  end
end
