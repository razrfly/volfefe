defmodule VolfefeMachineWeb.Admin.MarketJobsLive do
  use VolfefeMachineWeb, :live_view

  import Ecto.Query
  import LiveToast
  alias VolfefeMachine.{Repo, MarketData}
  alias VolfefeMachine.MarketData.Jobs

  @impl true
  def mount(_params, _session, socket) do
    if connected?(socket) do
      # Update stats every 3 seconds
      :timer.send_interval(3000, self(), :update_stats)
    end

    {:ok,
     socket
     |> assign(:page_title, "Market Data Jobs")
     |> assign(:baseline_form, to_form(%{}, as: :baseline))
     |> assign(:snapshot_form, to_form(%{}, as: :snapshot))
     |> assign(:baseline_asset_scope, :all)
     |> assign(:snapshot_limit, 10)
     |> load_data()}
  end

  @impl true
  def handle_event("update_baseline_asset_scope", %{"baseline" => %{"asset_scope" => scope}}, socket) do
    asset_scope = case scope do
      "all" -> :all
      asset_id when is_binary(asset_id) -> String.to_integer(asset_id)
      _ -> socket.assigns.baseline_asset_scope
    end
    {:noreply, assign(socket, :baseline_asset_scope, asset_scope)}
  end

  @impl true
  def handle_event("update_snapshot_limit", %{"snapshot" => %{"limit" => limit}}, socket) do
    snapshot_limit = case limit do
      "all_missing" -> :all_missing
      num when is_binary(num) -> String.to_integer(num)
      _ -> socket.assigns.snapshot_limit
    end
    {:noreply, assign(socket, :snapshot_limit, snapshot_limit)}
  end

  @impl true
  def handle_event("enqueue_baselines", params, socket) do
    lookback_days = String.to_integer(params["baseline"]["lookback_days"] || "60")
    force = params["baseline"]["force"] == "true"
    check_freshness = params["baseline"]["check_freshness"] == "true"

    {asset_ids, count_msg} = case socket.assigns.baseline_asset_scope do
      :all ->
        ids = Enum.map(socket.assigns.assets, & &1.id)
        {ids, "all #{length(ids)} assets"}

      asset_id when is_integer(asset_id) ->
        asset = Enum.find(socket.assigns.assets, & &1.id == asset_id)
        {[asset_id], "asset #{asset.symbol}"}
    end

    case Jobs.calculate_baselines_batch(asset_ids, lookback_days: lookback_days, force: force, check_freshness: check_freshness) do
      {:ok, _job} ->
        {:noreply,
         socket
         |> put_toast(:success, "Enqueued baseline calculation for #{count_msg}")
         |> load_data()}

      {:error, reason} ->
        {:noreply, put_toast(socket, :error, "Failed to enqueue: #{inspect(reason)}")}
    end
  end

  @impl true
  def handle_event("enqueue_snapshots", params, socket) do
    force = params["snapshot"]["force"] == "true"

    {content_ids, count_msg} = case socket.assigns.snapshot_limit do
      :all_missing ->
        ids = get_content_missing_snapshots()
        {ids, "#{length(ids)} content items missing snapshots"}

      limit when is_integer(limit) ->
        ids = get_recent_classified_content(limit)
        {ids, "most recent #{length(ids)} classified content"}
    end

    if length(content_ids) == 0 do
      {:noreply, put_toast(socket, :info, "No content to process")}
    else
      case Jobs.capture_snapshots_batch(content_ids, force: force) do
        {:ok, _job} ->
          {:noreply,
           socket
           |> put_toast(:success, "Enqueued snapshot capture for #{count_msg}")
           |> load_data()}

        {:error, reason} ->
          {:noreply, put_toast(socket, :error, "Failed to enqueue: #{inspect(reason)}")}
      end
    end
  end

  @impl true
  def handle_event("retry_job", %{"id" => job_id}, socket) do
    case retry_oban_job(String.to_integer(job_id)) do
      :ok ->
        {:noreply,
         socket
         |> put_toast(:success, "Job ##{job_id} retried successfully")
         |> load_data()}

      {:error, reason} ->
        {:noreply, put_toast(socket, :error, "Failed to retry job: #{inspect(reason)}")}
    end
  end

  @impl true
  def handle_event("cancel_job", %{"id" => job_id}, socket) do
    case cancel_oban_job(String.to_integer(job_id)) do
      :ok ->
        {:noreply,
         socket
         |> put_toast(:success, "Job ##{job_id} cancelled successfully")
         |> load_data()}

      {:error, reason} ->
        {:noreply, put_toast(socket, :error, "Failed to cancel job: #{inspect(reason)}")}
    end
  end

  @impl true
  def handle_info(:update_stats, socket) do
    {:noreply, load_data(socket)}
  end

  # Private functions

  defp load_data(socket) do
    socket
    |> assign(:job_stats, Jobs.get_job_stats())
    |> assign(:baseline_stats, Jobs.get_job_stats(operation: "baselines"))
    |> assign(:snapshot_stats, Jobs.get_job_stats(operation: "snapshots"))
    |> assign(:recent_jobs, get_recent_jobs())
    |> assign(:asset_count, count_assets())
    |> assign(:assets, MarketData.list_active())
    |> assign(:content_count, count_classified_content())
    |> assign(:missing_snapshots_count, count_missing_snapshots())
  end

  defp get_recent_jobs do
    from(j in Oban.Job,
      where: j.queue in ["market_baselines", "market_snapshots", "market_batch"],
      order_by: [desc: j.inserted_at],
      limit: 10,
      select: %{
        id: j.id,
        queue: j.queue,
        state: j.state,
        worker: j.worker,
        args: j.args,
        inserted_at: j.inserted_at,
        attempted_at: j.attempted_at,
        completed_at: j.completed_at
      }
    )
    |> Repo.all()
  end

  defp count_assets do
    from(a in MarketData.Asset, where: a.status == :active and a.tradable == true)
    |> Repo.aggregate(:count, :id)
  end

  defp count_classified_content do
    from(c in VolfefeMachine.Content.Content, where: c.classified == true)
    |> Repo.aggregate(:count, :id)
  end

  defp count_missing_snapshots do
    length(get_content_missing_snapshots())
  end

  defp get_content_missing_snapshots do
    import Ecto.Query
    alias VolfefeMachine.Content.Content
    alias VolfefeMachine.MarketData.Snapshot

    asset_count = count_assets()
    expected_snapshots = asset_count * 4

    incomplete_ids = from(c in Content,
      left_join: s in Snapshot, on: s.content_id == c.id,
      where: c.classified == true,
      group_by: c.id,
      having: count(s.id) < ^expected_snapshots,
      select: c.id
    ) |> Repo.all()

    no_snapshots = from(c in Content,
      left_join: s in Snapshot, on: s.content_id == c.id,
      where: c.classified == true and is_nil(s.id),
      select: c.id
    ) |> Repo.all()

    Enum.uniq(incomplete_ids ++ no_snapshots)
  end

  defp get_recent_classified_content(limit) do
    import Ecto.Query
    alias VolfefeMachine.Content.Content

    from(c in Content,
      where: c.classified == true,
      order_by: [desc: c.published_at],
      limit: ^limit,
      select: c.id
    )
    |> Repo.all()
  end

  # Template helper functions

  defp state_badge_class("available"), do: "bg-blue-100 text-blue-800"
  defp state_badge_class("executing"), do: "bg-yellow-100 text-yellow-800"
  defp state_badge_class("completed"), do: "bg-green-100 text-green-800"
  defp state_badge_class("retryable"), do: "bg-orange-100 text-orange-800"
  defp state_badge_class("discarded"), do: "bg-red-100 text-red-800"
  defp state_badge_class("cancelled"), do: "bg-gray-100 text-gray-800"
  defp state_badge_class(_), do: "bg-gray-100 text-gray-600"

  defp format_args(args) when is_map(args) do
    args
    |> Enum.map(fn {k, v} -> "#{k}: #{inspect(v)}" end)
    |> Enum.join(", ")
  end
  defp format_args(_), do: "-"

  defp retry_oban_job(job_id) do
    Oban.retry_job(Oban, job_id)
  end

  defp cancel_oban_job(job_id) do
    Oban.cancel_job(Oban, job_id)
  end
end
