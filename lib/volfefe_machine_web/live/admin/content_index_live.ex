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
      |> Repo.preload(:classification)

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
          <table class="min-w-full divide-y divide-gray-200">
            <thead class="bg-gray-50">
              <tr>
                <th
                  phx-click="sort"
                  phx-value-field="author"
                  class="px-6 py-3 text-left text-xs font-medium text-gray-500 uppercase tracking-wider cursor-pointer hover:bg-gray-100 transition-colors"
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
                <th class="px-6 py-3 text-left text-xs font-medium text-gray-500 uppercase tracking-wider">
                  Content
                </th>
                <th
                  phx-click="sort"
                  phx-value-field="published_at"
                  class="px-6 py-3 text-left text-xs font-medium text-gray-500 uppercase tracking-wider cursor-pointer hover:bg-gray-100 transition-colors"
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
                <th class="px-6 py-3 text-left text-xs font-medium text-gray-500 uppercase tracking-wider">
                  Sentiment
                </th>
                <th class="px-6 py-3 text-left text-xs font-medium text-gray-500 uppercase tracking-wider">
                  Confidence
                </th>
                <th class="px-6 py-3 text-left text-xs font-medium text-gray-500 uppercase tracking-wider">
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
                    <%= if content.classification do %>
                      <%= render_sentiment_badge(content.classification.sentiment) %>
                    <% else %>
                      <span class="text-xs text-gray-400">-</span>
                    <% end %>
                  </td>
                  <td class="px-6 py-4 whitespace-nowrap">
                    <%= if content.classification do %>
                      <div class="flex items-center">
                        <span class="text-sm font-medium text-gray-900">
                          <%= format_confidence(content.classification.confidence) %>
                        </span>
                        <div class="ml-2 w-16 bg-gray-200 rounded-full h-2">
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
                  <td class="px-6 py-4 whitespace-nowrap">
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
          <div class="fixed inset-y-0 right-0 w-full sm:w-2/3 lg:w-1/2 xl:w-2/5 bg-white shadow-xl z-50 overflow-y-auto">
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
                    <h4 class="text-xs font-semibold text-gray-700 mb-2">🏢 Extracted Entities</h4>
                    <ul class="text-xs text-gray-500 space-y-1">
                      <li>• Companies: [Pending]</li>
                      <li>• Locations: [Pending]</li>
                      <li>• People: [Pending]</li>
                    </ul>
                  </div>
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
end
