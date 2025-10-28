defmodule Mix.Tasks.Ml.Status do
  @moduledoc """
  Monitor ML reprocessing job status and queue health.

  This task provides real-time visibility into background ML jobs:
  - View job status across all queues
  - Filter by queue, state, or worker type
  - Display recent job history
  - Show queue health and performance metrics

  ## Usage

      # Show all recent jobs
      mix ml.status

      # Show only running jobs
      mix ml.status --state executing

      # Show sentiment queue jobs
      mix ml.status --queue ml_sentiment

      # Show failed jobs with details
      mix ml.status --state discarded --limit 10

      # Show batch worker jobs
      mix ml.status --worker BatchReprocessWorker

  ## Options

    * `--queue QUEUE` - Filter by queue: ml_sentiment, ml_ner, ml_batch
    * `--state STATE` - Filter by state: available, scheduled, executing, retryable, completed, discarded, cancelled
    * `--worker WORKER` - Filter by worker: SentimentWorker, NerWorker, BatchReprocessWorker
    * `--limit N` - Maximum number of jobs to display (default: 20)
    * `--all` - Show all jobs (overrides --limit)

  ## Job States

    * `available` - Ready to be executed
    * `scheduled` - Scheduled for future execution
    * `executing` - Currently running
    * `retryable` - Failed but will retry
    * `completed` - Successfully finished
    * `discarded` - Failed permanently after max attempts
    * `cancelled` - Manually cancelled

  ## Examples

      # Monitor active processing
      mix ml.status --state executing

      # Check for failures
      mix ml.status --state discarded

      # Monitor specific queue
      mix ml.status --queue ml_batch --limit 50

      # Recent batch operations
      mix ml.status --worker BatchReprocessWorker --all
  """

  use Mix.Task

  import Ecto.Query
  alias VolfefeMachine.Repo

  require Logger

  @shortdoc "Monitor ML reprocessing job status and queue health"

  @valid_queues ["ml_sentiment", "ml_ner", "ml_batch"]
  @valid_states ["available", "scheduled", "executing", "retryable", "completed", "discarded", "cancelled"]
  @valid_workers ["SentimentWorker", "NerWorker", "BatchReprocessWorker"]

  @impl Mix.Task
  def run(args) do
    # Start application for database access
    Mix.Task.run("app.start")

    # Parse command-line arguments
    {opts, _remaining, invalid} =
      OptionParser.parse(
        args,
        switches: [
          queue: :string,
          state: :string,
          worker: :string,
          limit: :integer,
          all: :boolean
        ],
        aliases: [
          q: :queue,
          s: :state,
          w: :worker,
          l: :limit,
          a: :all
        ]
      )

    # Handle invalid options
    if length(invalid) > 0 do
      Mix.shell().error("Invalid options: #{inspect(invalid)}")
      Mix.shell().error("Run `mix help ml.status` for usage information")
      exit({:shutdown, 1})
    end

    # Validate and normalize options
    case validate_and_normalize_opts(opts) do
      {:ok, normalized_opts} ->
        print_header(normalized_opts)
        print_queue_summary()
        print_jobs(normalized_opts)
        :ok

      {:error, reason} ->
        Mix.shell().error("\n❌ Error: #{reason}\n")
        Mix.shell().error("Run `mix help ml.status` for usage information")
        exit({:shutdown, 1})
    end
  end

  # Private functions

  defp validate_and_normalize_opts(opts) do
    with {:ok, queue} <- validate_queue(opts[:queue]),
         {:ok, state} <- validate_state(opts[:state]),
         {:ok, worker} <- validate_worker(opts[:worker]) do
      normalized = [
        queue: queue,
        state: state,
        worker: worker,
        limit: if(opts[:all], do: nil, else: opts[:limit] || 20)
      ]

      {:ok, normalized}
    end
  end

  defp validate_queue(nil), do: {:ok, nil}
  defp validate_queue(queue) when queue in @valid_queues, do: {:ok, queue}
  defp validate_queue(queue), do: {:error, "Invalid queue '#{queue}'. Must be: #{Enum.join(@valid_queues, ", ")}"}

  defp validate_state(nil), do: {:ok, nil}
  defp validate_state(state) when state in @valid_states, do: {:ok, state}
  defp validate_state(state), do: {:error, "Invalid state '#{state}'. Must be: #{Enum.join(@valid_states, ", ")}"}

  defp validate_worker(nil), do: {:ok, nil}
  defp validate_worker(worker) when worker in @valid_workers, do: {:ok, worker}
  defp validate_worker(worker), do: {:error, "Invalid worker '#{worker}'. Must be: #{Enum.join(@valid_workers, ", ")}"}

  defp print_header(opts) do
    Mix.shell().info("\n" <> String.duplicate("=", 80))
    Mix.shell().info("📊 ML Job Status Monitor")
    Mix.shell().info(String.duplicate("=", 80))

    filters = []
    filters = if opts[:queue], do: ["Queue: #{opts[:queue]}" | filters], else: filters
    filters = if opts[:state], do: ["State: #{opts[:state]}" | filters], else: filters
    filters = if opts[:worker], do: ["Worker: #{opts[:worker]}" | filters], else: filters

    if length(filters) > 0 do
      Mix.shell().info("Filters: #{Enum.join(filters, " | ")}")
    else
      Mix.shell().info("Showing: All jobs")
    end

    limit_desc = if opts[:limit], do: "Limit: #{opts[:limit]}", else: "Limit: All"
    Mix.shell().info(limit_desc)
    Mix.shell().info(String.duplicate("=", 80))
    Mix.shell().info("")
  end

  defp print_queue_summary do
    queues = ["ml_sentiment", "ml_ner", "ml_batch"]

    Mix.shell().info("🔍 Queue Health Summary")
    Mix.shell().info(String.duplicate("-", 80))

    Enum.each(queues, fn queue ->
      available = count_jobs(queue, "available")
      executing = count_jobs(queue, "executing")
      scheduled = count_jobs(queue, "scheduled")
      retryable = count_jobs(queue, "retryable")

      status_icon = cond do
        retryable > 0 -> "⚠️"
        executing > 0 -> "🔄"
        available > 0 -> "📋"
        true -> "✅"
      end

      Mix.shell().info("#{status_icon} #{String.pad_trailing(queue, 15)} | " <>
        "Available: #{String.pad_leading(to_string(available), 3)} | " <>
        "Executing: #{String.pad_leading(to_string(executing), 3)} | " <>
        "Scheduled: #{String.pad_leading(to_string(scheduled), 3)} | " <>
        "Retryable: #{String.pad_leading(to_string(retryable), 3)}")
    end)

    Mix.shell().info("")
  end

  defp print_jobs(opts) do
    jobs = fetch_jobs(opts)

    if length(jobs) == 0 do
      Mix.shell().info("No jobs found matching criteria.\n")
    else
      Mix.shell().info("📋 Recent Jobs (#{length(jobs)})")
      Mix.shell().info(String.duplicate("-", 80))

      Enum.each(jobs, fn job ->
        print_job(job)
      end)

      Mix.shell().info("")
    end
  end

  defp print_job(job) do
    state_icon = case job.state do
      "available" -> "📋"
      "scheduled" -> "⏰"
      "executing" -> "🔄"
      "retryable" -> "🔁"
      "completed" -> "✅"
      "discarded" -> "❌"
      "cancelled" -> "🚫"
      _ -> "❓"
    end

    worker_name = job.worker |> String.split(".") |> List.last()

    # Extract content_id or content_ids from args
    content_info = case job.args do
      %{"content_id" => id} -> "content_id=#{id}"
      %{"content_ids" => ids} when is_list(ids) -> "#{length(ids)} items"
      _ -> "unknown"
    end

    attempt_info = if job.attempt > 0 do
      " (attempt #{job.attempt}/#{job.max_attempts})"
    else
      ""
    end

    Mix.shell().info("#{state_icon} [#{job.id}] #{worker_name} | #{job.queue} | #{job.state}#{attempt_info}")
    Mix.shell().info("   #{content_info} | scheduled: #{format_datetime(job.scheduled_at)}")

    if job.state == "executing" and job.attempted_at do
      Mix.shell().info("   ⏱️  Started: #{format_datetime(job.attempted_at)}")
    end

    if job.state == "completed" and job.completed_at do
      Mix.shell().info("   ✅ Completed: #{format_datetime(job.completed_at)}")
    end

    if job.state in ["retryable", "discarded"] and job.errors do
      latest_error = List.first(job.errors)
      if latest_error do
        error_msg = latest_error["error"] || "Unknown error"
        Mix.shell().info("   ❌ Error: #{String.slice(error_msg, 0..80)}")
      end
    end

    Mix.shell().info("")
  end

  defp fetch_jobs(opts) do
    query = from j in "oban_jobs",
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
        errors: j.errors,
        inserted_at: j.inserted_at
      },
      order_by: [desc: j.inserted_at]

    # Apply filters
    query = if opts[:queue], do: where(query, [j], j.queue == ^opts[:queue]), else: query
    query = if opts[:state], do: where(query, [j], j.state == ^opts[:state]), else: query

    query = if opts[:worker] do
      worker_module = "Elixir.VolfefeMachine.Workers.#{opts[:worker]}"
      where(query, [j], j.worker == ^worker_module)
    else
      query
    end

    # Apply limit
    query = if opts[:limit], do: limit(query, ^opts[:limit]), else: query

    Repo.all(query)
  end

  defp count_jobs(queue, state) do
    from(j in "oban_jobs",
      where: j.queue == ^queue and j.state == ^state,
      select: count(j.id)
    )
    |> Repo.one()
  end

  defp format_datetime(nil), do: "N/A"
  defp format_datetime(%DateTime{} = dt) do
    Calendar.strftime(dt, "%Y-%m-%d %H:%M:%S")
  end
  defp format_datetime(%NaiveDateTime{} = dt) do
    Calendar.strftime(dt, "%Y-%m-%d %H:%M:%S")
  end
end
