defmodule VolfefeMachineWeb.Admin.MLDashboardLive do
  use VolfefeMachineWeb, :live_view

  import Ecto.Query
  alias VolfefeMachine.Repo
  alias VolfefeMachine.Intelligence.{ModelRegistry, Reprocessor}
  alias VolfefeMachine.Content

  @impl true
  def mount(_params, _session, socket) do
    if connected?(socket) do
      # Update stats every 3 seconds
      :timer.send_interval(3000, self(), :update_stats)
    end

    {:ok,
     socket
     |> assign(:page_title, "ML Dashboard")
     |> assign(:form, to_form(%{}, as: :reprocess))
     |> assign(:model_type, :all)
     |> assign(:content_scope, :unclassified)
     |> load_initial_data()}
  end

  @impl true
  def handle_params(params, _url, socket) do
    {:noreply, apply_action(socket, socket.assigns.live_action, params)}
  end

  defp apply_action(socket, :index, _params) do
    socket
    |> assign(:page_title, "ML Dashboard")
  end

  @impl true
  def handle_event("update_model_type", %{"reprocess" => %{"model_type" => type}}, socket) do
    {:noreply, assign(socket, :model_type, String.to_atom(type))}
  end

  @impl true
  def handle_event("update_content_scope", %{"reprocess" => %{"content_scope" => scope}}, socket) do
    {:noreply, assign(socket, :content_scope, String.to_atom(scope))}
  end

  @impl true
  def handle_event("enqueue_reprocess", params, socket) do
    reprocess_params = params["reprocess"]

    opts = build_reprocess_opts(reprocess_params)

    case Reprocessor.reprocess(Keyword.put(opts, :async, true)) do
      {:ok, result} ->
        {:noreply,
         socket
         |> put_flash(:info, "Successfully enqueued #{result.enqueued_jobs} job(s) for #{result.total} items")
         |> load_initial_data()}

      {:error, reason} ->
        {:noreply, put_flash(socket, :error, "Failed to enqueue jobs: #{inspect(reason)}")}
    end
  end

  @impl true
  def handle_event("retry_job", %{"id" => job_id}, socket) do
    case retry_oban_job(String.to_integer(job_id)) do
      {:ok, _} ->
        {:noreply,
         socket
         |> put_flash(:info, "Job ##{job_id} retried successfully")
         |> load_initial_data()}

      {:error, reason} ->
        {:noreply, put_flash(socket, :error, "Failed to retry job: #{inspect(reason)}")}
    end
  end

  @impl true
  def handle_event("cancel_job", %{"id" => job_id}, socket) do
    case cancel_oban_job(String.to_integer(job_id)) do
      {:ok, _} ->
        {:noreply,
         socket
         |> put_flash(:info, "Job ##{job_id} cancelled successfully")
         |> load_initial_data()}

      {:error, reason} ->
        {:noreply, put_flash(socket, :error, "Failed to cancel job: #{inspect(reason)}")}
    end
  end

  @impl true
  def handle_event("clear_all_classifications", _params, socket) do
    case clear_all_classifications() do
      {:ok, count} ->
        {:noreply,
         socket
         |> put_flash(:info, "Successfully cleared #{count} classification(s)")
         |> load_initial_data()}

      {:error, reason} ->
        {:noreply, put_flash(socket, :error, "Failed to clear classifications: #{inspect(reason)}")}
    end
  end

  @impl true
  def handle_info(:update_stats, socket) do
    {:noreply, load_initial_data(socket)}
  end

  # Private functions

  defp load_initial_data(socket) do
    socket
    |> assign(:queue_stats, fetch_queue_stats())
    |> assign(:recent_jobs, fetch_recent_jobs(20))
    |> assign(:models, ModelRegistry.list_models())
  end

  defp fetch_queue_stats do
    queues = ["ml_sentiment", "ml_ner", "ml_batch"]

    Enum.map(queues, fn queue ->
      %{
        name: queue,
        available: count_jobs(queue, "available"),
        scheduled: count_jobs(queue, "scheduled"),
        executing: count_jobs(queue, "executing"),
        completed: count_completed_jobs(queue),
        retryable: count_jobs(queue, "retryable"),
        discarded: count_jobs(queue, "discarded")
      }
    end)
  end

  defp fetch_recent_jobs(limit) do
    query =
      from j in "oban_jobs",
        select: %{
          id: j.id,
          state: j.state,
          queue: j.queue,
          worker: j.worker,
          args: j.args,
          attempt: j.attempt,
          max_attempts: j.max_attempts,
          scheduled_at: j.scheduled_at,
          attempted_at: j.attempted_at,
          completed_at: j.completed_at,
          discarded_at: j.discarded_at,
          errors: j.errors,
          inserted_at: j.inserted_at
        },
        where: j.queue in ["ml_sentiment", "ml_ner", "ml_batch"],
        order_by: [desc: j.inserted_at],
        limit: ^limit

    Repo.all(query)
  end

  defp count_jobs(queue, state) do
    from(j in "oban_jobs",
      where: j.queue == ^queue and j.state == ^state,
      select: count(j.id)
    )
    |> Repo.one()
  end

  defp count_completed_jobs(queue) do
    # Count jobs completed in last 24 hours
    one_day_ago = DateTime.utc_now() |> DateTime.add(-24, :hour)

    from(j in "oban_jobs",
      where:
        j.queue == ^queue and
          j.state == "completed" and
          j.completed_at > ^one_day_ago,
      select: count(j.id)
    )
    |> Repo.one()
  end

  defp build_reprocess_opts(params) do
    opts = [
      force: params["force"] == "true"
    ]

    # Add model selection
    opts =
      case params["model_type"] do
        "all" -> opts
        "sentiment" -> Keyword.put(opts, :model_type, :sentiment)
        "ner" -> Keyword.put(opts, :model_type, :ner)
        _ -> opts
      end

    # Add specific model if selected
    opts =
      if params["model"] && params["model"] != "" do
        Keyword.put(opts, :model, params["model"])
      else
        opts
      end

    # Add content scope
    opts =
      case params["content_scope"] do
        "all" -> Keyword.put(opts, :all, true)
        "unclassified" -> opts
        "ids" -> parse_content_ids(params["content_ids"], opts)
        _ -> opts
      end

    # Add limit if not processing all
    opts =
      if !Keyword.get(opts, :all) && !Keyword.has_key?(opts, :content_ids) do
        limit = String.to_integer(params["limit"] || "10")
        Keyword.put(opts, :limit, limit)
      else
        opts
      end

    opts
  end

  defp parse_content_ids(ids_string, opts) when is_binary(ids_string) do
    ids =
      ids_string
      |> String.split(",")
      |> Enum.map(&String.trim/1)
      |> Enum.reject(&(&1 == ""))
      |> Enum.map(&String.to_integer/1)

    Keyword.put(opts, :content_ids, ids)
  rescue
    _ -> opts
  end

  defp parse_content_ids(_, opts), do: opts

  defp retry_oban_job(job_id) do
    # Update job state to available and reset attempt counter
    query =
      from j in "oban_jobs",
        where: j.id == ^job_id,
        update: [
          set: [
            state: "available",
            scheduled_at: ^DateTime.utc_now(),
            max_attempts: fragment("? + 1", j.max_attempts)
          ]
        ]

    case Repo.update_all(query, []) do
      {1, _} -> {:ok, :retried}
      {0, _} -> {:error, :not_found}
    end
  end

  defp cancel_oban_job(job_id) do
    query =
      from j in "oban_jobs",
        where: j.id == ^job_id and j.state in ["available", "scheduled", "retryable"],
        update: [
          set: [
            state: "cancelled",
            cancelled_at: ^DateTime.utc_now()
          ]
        ]

    case Repo.update_all(query, []) do
      {1, _} -> {:ok, :cancelled}
      {0, _} -> {:error, :not_found_or_invalid_state}
    end
  end

  defp clear_all_classifications do
    require Logger

    try do
      # Step 1: Delete from model_classifications first (child records)
      {model_count, _} = Repo.delete_all("model_classifications")
      Logger.info("Deleted #{model_count} model classification(s)")

      # Step 2: Delete from classifications (parent records)
      {class_count, _} = Repo.delete_all("classifications")
      Logger.info("Deleted #{class_count} classification(s)")

      # Step 3: Reset the classified flag on all content records
      {:ok, unclassified_count} = Content.mark_all_as_unclassified()
      Logger.info("Reset classified flag on #{unclassified_count} content record(s)")

      total = model_count + class_count
      {:ok, total}
    rescue
      error ->
        Logger.error("Failed to clear classifications: #{inspect(error)}")
        {:error, error}
    end
  end

  # Helper functions for templates

  def worker_name(worker_string) do
    worker_string
    |> String.split(".")
    |> List.last()
  end

  def format_datetime(nil), do: "N/A"

  def format_datetime(%DateTime{} = dt) do
    Calendar.strftime(dt, "%Y-%m-%d %H:%M:%S")
  end

  def format_datetime(%NaiveDateTime{} = dt) do
    Calendar.strftime(dt, "%Y-%m-%d %H:%M:%S")
  end

  def relative_time(nil), do: "N/A"

  def relative_time(%DateTime{} = dt) do
    seconds = DateTime.diff(DateTime.utc_now(), dt)
    format_relative_seconds(seconds)
  end

  def relative_time(%NaiveDateTime{} = dt) do
    # Convert to DateTime assuming UTC
    {:ok, datetime} = DateTime.from_naive(dt, "Etc/UTC")
    relative_time(datetime)
  end

  defp format_relative_seconds(seconds) when seconds < 60, do: "#{seconds}s ago"
  defp format_relative_seconds(seconds) when seconds < 3600, do: "#{div(seconds, 60)}m ago"
  defp format_relative_seconds(seconds) when seconds < 86400, do: "#{div(seconds, 3600)}h ago"
  defp format_relative_seconds(seconds), do: "#{div(seconds, 86400)}d ago"

  def job_content_info(%{"content_id" => id}), do: "content_id=#{id}"
  def job_content_info(%{"content_ids" => ids}) when is_list(ids), do: "#{length(ids)} items"
  def job_content_info(_), do: "unknown"

  def state_badge_class("available"), do: "bg-blue-100 text-blue-800"
  def state_badge_class("scheduled"), do: "bg-purple-100 text-purple-800"
  def state_badge_class("executing"), do: "bg-yellow-100 text-yellow-800"
  def state_badge_class("retryable"), do: "bg-orange-100 text-orange-800"
  def state_badge_class("completed"), do: "bg-green-100 text-green-800"
  def state_badge_class("discarded"), do: "bg-red-100 text-red-800"
  def state_badge_class("cancelled"), do: "bg-gray-100 text-gray-800"
  def state_badge_class(_), do: "bg-gray-100 text-gray-800"

  def state_icon("available"), do: "📋"
  def state_icon("scheduled"), do: "⏰"
  def state_icon("executing"), do: "🔄"
  def state_icon("retryable"), do: "🔁"
  def state_icon("completed"), do: "✅"
  def state_icon("discarded"), do: "❌"
  def state_icon("cancelled"), do: "🚫"
  def state_icon(_), do: "❓"

  def queue_status_icon(stats) do
    cond do
      stats.discarded > 0 -> "❌"
      stats.retryable > 0 -> "⚠️"
      stats.executing > 0 -> "🔄"
      stats.available > 0 -> "📋"
      true -> "✅"
    end
  end

  def available_models(:all), do: ModelRegistry.list_models()
  def available_models(:sentiment), do: ModelRegistry.models_by_type("sentiment")
  def available_models(:ner), do: ModelRegistry.models_by_type("ner")
end
