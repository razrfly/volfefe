defmodule VolfefeMachineWeb.Admin.ImportLive do
  @moduledoc """
  Admin interface for importing social media content.

  Provides:
  - Current import status and statistics
  - One-click import buttons for different modes
  - Date range backfill form
  - Recent import job monitoring
  """
  use VolfefeMachineWeb, :live_view

  alias VolfefeMachine.Ingestion.ImportAnalyzer
  alias VolfefeMachine.Workers.ImportContentWorker
  alias VolfefeMachine.Repo

  import Ecto.Query

  @impl true
  def mount(_params, _session, socket) do
    # Refresh every 5 seconds if there are running jobs
    if connected?(socket) do
      :timer.send_interval(5000, self(), :refresh_jobs)
    end

    {:ok,
     socket
     |> assign(:page_title, "Content Imports")
     |> assign(:source, "truth_social")
     |> assign(:username, "realDonaldTrump")
     |> assign(:loading, false)
     |> assign(:backfill_start_date, "")
     |> assign(:backfill_end_date, "")
     |> assign(:custom_limit, "")
     |> load_status()
     |> load_recent_jobs()}
  end

  @impl true
  def handle_event("import_newest", _params, socket) do
    source = socket.assigns.source
    username = socket.assigns.username

    job_params = %{
      source: source,
      username: username,
      mode: "newest"
    }

    case ImportContentWorker.new(job_params) |> Oban.insert() do
      {:ok, job} ->
        {:noreply,
         socket
         |> put_flash(:info, "Import job enqueued! Job ID: #{job.id}")
         |> load_recent_jobs()}

      {:error, changeset} ->
        {:noreply,
         socket
         |> put_flash(:error, "Failed to enqueue job: #{inspect(changeset.errors)}")}
    end
  end

  @impl true
  def handle_event("import_backfill", %{"start_date" => start_date, "end_date" => end_date}, socket) do
    source = socket.assigns.source
    username = socket.assigns.username

    with {:ok, _} <- Date.from_iso8601(start_date),
         {:ok, _} <- Date.from_iso8601(end_date) do
      job_params = %{
        source: source,
        username: username,
        mode: "backfill",
        date_range: %{start_date: start_date, end_date: end_date},
        limit: 500
      }

      case ImportContentWorker.new(job_params) |> Oban.insert() do
        {:ok, job} ->
          {:noreply,
           socket
           |> assign(:backfill_start_date, "")
           |> assign(:backfill_end_date, "")
           |> put_flash(:info, "Backfill job enqueued! Job ID: #{job.id}")
           |> load_recent_jobs()}

        {:error, changeset} ->
          {:noreply,
           socket
           |> put_flash(:error, "Failed to enqueue job: #{inspect(changeset.errors)}")}
      end
    else
      _ ->
        {:noreply,
         socket
         |> put_flash(:error, "Invalid date format. Use YYYY-MM-DD")}
    end
  end

  @impl true
  def handle_event("import_full", %{"limit" => limit_str}, socket) do
    source = socket.assigns.source
    username = socket.assigns.username

    limit =
      case Integer.parse(limit_str) do
        {num, _} when num > 0 and num <= 10_000 -> num
        _ -> 100
      end

    job_params = %{
      source: source,
      username: username,
      mode: "full",
      limit: limit
    }

    case ImportContentWorker.new(job_params) |> Oban.insert() do
      {:ok, job} ->
        {:noreply,
         socket
         |> assign(:custom_limit, "")
         |> put_flash(:info, "Full import job enqueued! Job ID: #{job.id}")
         |> load_recent_jobs()}

      {:error, changeset} ->
        {:noreply,
         socket
         |> put_flash(:error, "Failed to enqueue job: #{inspect(changeset.errors)}")}
    end
  end

  @impl true
  def handle_event("cancel_job", %{"job_id" => job_id}, socket) do
    case Integer.parse(job_id) do
      {id, ""} ->
        case Oban.cancel_job(id) do
          {:ok, _job} ->
            {:noreply,
             socket
             |> put_flash(:info, "Job cancelled")
             |> load_recent_jobs()}

          {:error, _reason} ->
            {:noreply,
             socket
             |> put_flash(:error, "Failed to cancel job")}
        end

      _ ->
        {:noreply,
         socket
         |> put_flash(:error, "Invalid job identifier")}
    end
  end

  @impl true
  def handle_info(:refresh_jobs, socket) do
    {:noreply, load_recent_jobs(socket)}
  end

  # Private functions

  defp load_status(socket) do
    source = socket.assigns.source
    username = socket.assigns.username

    case ImportAnalyzer.analyze_import_status(source, username) do
      {:ok, analysis} ->
        assign(socket, :analysis, analysis)

      {:error, _} ->
        assign(socket, :analysis, nil)
    end
  end

  defp load_recent_jobs(socket) do
    jobs =
      from(j in Oban.Job,
        where: j.queue == "content_import",
        order_by: [desc: j.inserted_at],
        limit: 10,
        select: %{
          id: j.id,
          state: j.state,
          args: j.args,
          meta: j.meta,
          attempt: j.attempt,
          max_attempts: j.max_attempts,
          inserted_at: j.inserted_at,
          scheduled_at: j.scheduled_at,
          attempted_at: j.attempted_at,
          completed_at: j.completed_at,
          errors: j.errors
        }
      )
      |> Repo.all()

    assign(socket, :recent_jobs, jobs)
  end

  @impl true
  def render(assigns) do
    ~H"""
    <div class="max-w-7xl mx-auto px-4 sm:px-6 lg:px-8 py-8">
      <!-- Admin Navigation -->
      <.admin_nav current_page={:imports} />

      <div class="mb-8">
        <h1 class="text-3xl font-bold text-gray-900">Content Imports</h1>
        <p class="mt-2 text-sm text-gray-600">
          Import social media content from Truth Social
        </p>
      </div>

      <!-- Import Status Section -->
      <%= if @analysis do %>
        <div class="bg-white shadow rounded-lg p-6 mb-8 border border-gray-200">
          <h2 class="text-xl font-semibold text-gray-900 mb-4">Current Status - @<%= @analysis.username %></h2>

          <div class="grid grid-cols-1 md:grid-cols-3 gap-4 mb-6">
            <!-- Total Posts -->
            <div class="bg-blue-50 rounded-lg p-4">
              <p class="text-sm text-blue-600 font-medium">Total Posts</p>
              <p class="text-2xl font-bold text-blue-900"><%= @analysis.total_posts %></p>
            </div>

            <!-- Last Import -->
            <div class="bg-green-50 rounded-lg p-4">
              <p class="text-sm text-green-600 font-medium">Last Import</p>
              <p class="text-lg font-semibold text-green-900">
                <%= if @analysis.last_import do %>
                  <%= format_datetime(@analysis.last_import) %>
                <% else %>
                  Never
                <% end %>
              </p>
            </div>

            <!-- Estimated New -->
            <div class="bg-purple-50 rounded-lg p-4">
              <p class="text-sm text-purple-600 font-medium">Estimated New</p>
              <p class="text-2xl font-bold text-purple-900">
                <%= if @analysis.estimated_new, do: "~#{@analysis.estimated_new}", else: "N/A" %>
              </p>
            </div>
          </div>

          <!-- Date Range -->
          <%= if @analysis.date_range do %>
            <% {first, last} = @analysis.date_range %>
            <p class="text-sm text-gray-600 mb-4">
              📅 Date Range: <%= Date.to_string(DateTime.to_date(first)) %> to <%= Date.to_string(DateTime.to_date(last)) %>
            </p>
          <% end %>

          <!-- Posting Stats -->
          <p class="text-sm text-gray-600 mb-4">
            📊 Average: <%= @analysis.posting_stats.avg_per_day %> posts/day
          </p>

          <!-- Gaps -->
          <%= if length(@analysis.gaps) > 0 do %>
            <div class="bg-yellow-50 border-l-4 border-yellow-400 p-4 mb-4">
              <div class="flex">
                <div class="flex-shrink-0">
                  <svg class="h-5 w-5 text-yellow-400" fill="currentColor" viewBox="0 0 20 20">
                    <path fill-rule="evenodd" d="M8.257 3.099c.765-1.36 2.722-1.36 3.486 0l5.58 9.92c.75 1.334-.213 2.98-1.742 2.98H4.42c-1.53 0-2.493-1.646-1.743-2.98l5.58-9.92zM11 13a1 1 0 11-2 0 1 1 0 012 0zm-1-8a1 1 0 00-1 1v3a1 1 0 002 0V6a1 1 0 00-1-1z" clip-rule="evenodd" />
                  </svg>
                </div>
                <div class="ml-3">
                  <p class="text-sm text-yellow-700 font-medium">
                    <%= length(@analysis.gaps) %> gap(s) detected
                  </p>
                  <ul class="mt-2 text-sm text-yellow-700 list-disc list-inside">
                    <%= for gap <- Enum.take(@analysis.gaps, 3) do %>
                      <li><%= gap.gap_start %> to <%= gap.gap_end %> (<%= gap.days %> days)</li>
                    <% end %>
                  </ul>
                </div>
              </div>
            </div>
          <% else %>
            <div class="bg-green-50 border-l-4 border-green-400 p-4">
              <p class="text-sm text-green-700">✅ No significant gaps detected</p>
            </div>
          <% end %>
        </div>
      <% else %>
        <div class="bg-gray-50 rounded-lg p-6 mb-8">
          <p class="text-gray-500">Loading import status...</p>
        </div>
      <% end %>

      <!-- Import Actions Section -->
      <div class="grid grid-cols-1 lg:grid-cols-3 gap-6 mb-8">
        <!-- Incremental Import -->
        <div class="bg-white shadow rounded-lg p-6 border border-gray-200">
          <h3 class="text-lg font-semibold text-gray-900 mb-2">🔄 Incremental Import</h3>
          <p class="text-sm text-gray-600 mb-4">
            Import only new posts since last import. Automatically calculates optimal fetch limit.
          </p>
          <button
            phx-click="import_newest"
            class="w-full bg-blue-600 hover:bg-blue-700 text-white font-medium py-2 px-4 rounded-lg transition"
          >
            Import New Posts
          </button>
          <%= if @analysis && @analysis.estimated_new do %>
            <p class="text-xs text-gray-500 mt-2 text-center">
              Will fetch ~<%= @analysis.estimated_new %> posts
            </p>
          <% end %>
        </div>

        <!-- Backfill -->
        <div class="bg-white shadow rounded-lg p-6 border border-gray-200">
          <h3 class="text-lg font-semibold text-gray-900 mb-2">🔍 Backfill Gap</h3>
          <p class="text-sm text-gray-600 mb-4">
            Fill missing posts in a specific date range.
          </p>
          <form phx-submit="import_backfill" class="space-y-3">
            <input
              type="date"
              name="start_date"
              value={@backfill_start_date}
              class="w-full px-3 py-2 border border-gray-300 rounded-lg text-sm"
              placeholder="Start date"
              required
            />
            <input
              type="date"
              name="end_date"
              value={@backfill_end_date}
              class="w-full px-3 py-2 border border-gray-300 rounded-lg text-sm"
              placeholder="End date"
              required
            />
            <button
              type="submit"
              class="w-full bg-yellow-600 hover:bg-yellow-700 text-white font-medium py-2 px-4 rounded-lg transition"
            >
              Fill Gap
            </button>
          </form>
        </div>

        <!-- Full Import -->
        <div class="bg-white shadow rounded-lg p-6 border border-gray-200">
          <h3 class="text-lg font-semibold text-gray-900 mb-2">📚 Full Import</h3>
          <p class="text-sm text-gray-600 mb-4">
            Import with custom limit for large historical imports.
          </p>
          <form phx-submit="import_full" class="space-y-3">
            <input
              type="number"
              name="limit"
              value={@custom_limit}
              min="1"
              max="10000"
              class="w-full px-3 py-2 border border-gray-300 rounded-lg text-sm"
              placeholder="Post limit (1-10000)"
              required
            />
            <button
              type="submit"
              class="w-full bg-purple-600 hover:bg-purple-700 text-white font-medium py-2 px-4 rounded-lg transition"
            >
              Start Import
            </button>
          </form>
          <p class="text-xs text-gray-500 mt-2 text-center">
            Large imports may take 5-10 minutes
          </p>
        </div>
      </div>

      <!-- Recent Jobs Section -->
      <div class="bg-white shadow rounded-lg p-6 border border-gray-200">
        <h2 class="text-xl font-semibold text-gray-900 mb-4">Recent Import Jobs</h2>

        <%= if length(@recent_jobs) == 0 do %>
          <p class="text-gray-500 text-sm">No import jobs yet</p>
        <% else %>
          <div class="space-y-3">
            <%= for job <- @recent_jobs do %>
              <div class="border border-gray-200 rounded-lg p-4">
                <div class="flex justify-between items-start">
                  <div class="flex-1">
                    <div class="flex items-center gap-2 mb-2">
                      <span class={"#{job_status_badge_class(job.state)} px-2 py-1 text-xs font-medium rounded"}>
                        <%= format_job_state(job.state) %>
                      </span>
                      <span class="text-sm text-gray-600">
                        Job #<%= job.id %> - <%= job.args["mode"] %>
                      </span>
                    </div>

                    <%= if job.meta && job.meta["status"] do %>
                      <p class="text-sm text-gray-600 mb-1">
                        Status: <%= job.meta["status"] %>
                        <%= if job.meta["imported"] do %>
                          - Imported: <%= job.meta["imported"] %>
                        <% end %>
                      </p>
                    <% end %>

                    <p class="text-xs text-gray-500">
                      Started: <%= format_datetime(job.inserted_at) %>
                      <%= if job.completed_at do %>
                        | Completed: <%= format_datetime(job.completed_at) %>
                      <% end %>
                    </p>
                  </div>

                  <%= if job.state in ["available", "scheduled", "executing"] do %>
                    <button
                      phx-click="cancel_job"
                      phx-value-job_id={job.id}
                      class="text-red-600 hover:text-red-700 text-sm"
                    >
                      Cancel
                    </button>
                  <% end %>
                </div>
              </div>
            <% end %>
          </div>
        <% end %>

        <div class="mt-4 pt-4 border-t border-gray-200">
          <a href="/admin/oban" class="text-sm text-blue-600 hover:text-blue-700">
            View all jobs in Oban Dashboard →
          </a>
        </div>
      </div>
    </div>
    """
  end

  # Helper functions

  defp format_datetime(nil), do: "N/A"

  defp format_datetime(%DateTime{} = dt) do
    Calendar.strftime(dt, "%Y-%m-%d %H:%M")
  end

  defp format_datetime(%NaiveDateTime{} = dt) do
    Calendar.strftime(dt, "%Y-%m-%d %H:%M")
  end

  defp format_job_state("available"), do: "Queued"
  defp format_job_state("scheduled"), do: "Scheduled"
  defp format_job_state("executing"), do: "Running"
  defp format_job_state("completed"), do: "✅ Complete"
  defp format_job_state("discarded"), do: "❌ Failed"
  defp format_job_state("cancelled"), do: "🚫 Cancelled"
  defp format_job_state(state), do: state

  defp job_status_badge_class("available"), do: "bg-gray-100 text-gray-800"
  defp job_status_badge_class("scheduled"), do: "bg-blue-100 text-blue-800"
  defp job_status_badge_class("executing"), do: "bg-yellow-100 text-yellow-800"
  defp job_status_badge_class("completed"), do: "bg-green-100 text-green-800"
  defp job_status_badge_class("discarded"), do: "bg-red-100 text-red-800"
  defp job_status_badge_class("cancelled"), do: "bg-gray-100 text-gray-800"
  defp job_status_badge_class(_), do: "bg-gray-100 text-gray-800"
end
