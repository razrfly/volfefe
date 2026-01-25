defmodule VolfefeMachine.Polymarket.DataSourceHealth do
  @moduledoc """
  Monitors health status of Polymarket data sources.

  Tracks availability and latency for:
  - Centralized API (data-api.polymarket.com, gamma-api.polymarket.com)
  - Blockchain Subgraph (Goldsky/The Graph)

  Used by Client.ex for automatic failover decisions.
  """

  use GenServer
  require Logger

  alias VolfefeMachine.Polymarket.SubgraphClient

  @check_interval :timer.minutes(2)
  @api_timeout :timer.seconds(10)

  # Health status thresholds
  @healthy_threshold 0.8  # 80% success rate to be considered healthy
  @recent_window 10       # Number of recent requests to track

  defstruct [
    :api_status,
    :subgraph_status,
    :api_last_success,
    :api_last_failure,
    :subgraph_last_success,
    :subgraph_last_failure,
    :api_recent_results,
    :subgraph_recent_results,
    :started_at
  ]

  # ============================================================================
  # Client API
  # ============================================================================

  def start_link(opts \\ []) do
    GenServer.start_link(__MODULE__, opts, name: __MODULE__)
  end

  @doc """
  Get current health status of all data sources.
  """
  def health_summary do
    GenServer.call(__MODULE__, :health_summary)
  catch
    :exit, _ -> fallback_health_summary()
  end

  @doc """
  Check if centralized API is healthy.
  """
  def api_healthy? do
    case health_summary() do
      %{api: %{healthy: healthy}} -> healthy
      _ -> false
    end
  end

  @doc """
  Check if blockchain subgraph is healthy.
  """
  def subgraph_healthy? do
    case health_summary() do
      %{subgraph: %{healthy: healthy}} -> healthy
      _ -> true  # Default to true for subgraph (more reliable)
    end
  end

  @doc """
  Get the recommended data source based on current health.
  Returns :subgraph or :api
  """
  def recommended_source do
    summary = health_summary()

    cond do
      # Subgraph healthy - prefer it (more reliable)
      summary.subgraph.healthy -> :subgraph

      # API healthy and subgraph not - use API
      summary.api.healthy -> :api

      # Neither healthy - try subgraph anyway (usually recovers faster)
      true -> :subgraph
    end
  end

  @doc """
  Record a successful API request.
  """
  def record_api_success do
    GenServer.cast(__MODULE__, {:record_result, :api, :success})
  catch
    :exit, _ -> :ok
  end

  @doc """
  Record a failed API request.
  """
  def record_api_failure(reason \\ nil) do
    GenServer.cast(__MODULE__, {:record_result, :api, {:failure, reason}})
  catch
    :exit, _ -> :ok
  end

  @doc """
  Record a successful subgraph request.
  """
  def record_subgraph_success do
    GenServer.cast(__MODULE__, {:record_result, :subgraph, :success})
  catch
    :exit, _ -> :ok
  end

  @doc """
  Record a failed subgraph request.
  """
  def record_subgraph_failure(reason \\ nil) do
    GenServer.cast(__MODULE__, {:record_result, :subgraph, {:failure, reason}})
  catch
    :exit, _ -> :ok
  end

  @doc """
  Force an immediate health check of both sources.
  """
  def check_now do
    GenServer.call(__MODULE__, :check_now, @api_timeout * 3)
  catch
    :exit, _ -> {:error, :not_running}
  end

  # ============================================================================
  # GenServer Callbacks
  # ============================================================================

  @impl true
  def init(_opts) do
    state = %__MODULE__{
      api_status: :unknown,
      subgraph_status: :unknown,
      api_last_success: nil,
      api_last_failure: nil,
      subgraph_last_success: nil,
      subgraph_last_failure: nil,
      api_recent_results: [],
      subgraph_recent_results: [],
      started_at: DateTime.utc_now()
    }

    # Schedule initial health check
    Process.send_after(self(), :check_health, 1000)

    # Schedule periodic health checks
    :timer.send_interval(@check_interval, self(), :check_health)

    {:ok, state}
  end

  @impl true
  def handle_call(:health_summary, _from, state) do
    summary = build_health_summary(state)
    {:reply, summary, state}
  end

  @impl true
  def handle_call(:check_now, _from, state) do
    new_state = perform_health_checks(state)
    summary = build_health_summary(new_state)
    {:reply, {:ok, summary}, new_state}
  end

  @impl true
  def handle_cast({:record_result, source, result}, state) do
    new_state = record_result(state, source, result)
    {:noreply, new_state}
  end

  @impl true
  def handle_info(:check_health, state) do
    new_state = perform_health_checks(state)
    {:noreply, new_state}
  end

  # ============================================================================
  # Private Functions
  # ============================================================================

  defp perform_health_checks(state) do
    state
    |> check_api_health()
    |> check_subgraph_health()
  end

  defp check_api_health(state) do
    # Quick health check against gamma API (markets endpoint)
    url = "https://gamma-api.polymarket.com/markets?limit=1"

    case HTTPoison.get(url, [], recv_timeout: @api_timeout, timeout: @api_timeout) do
      {:ok, %HTTPoison.Response{status_code: 200}} ->
        Logger.debug("[DataSourceHealth] API health check: OK")
        record_result(state, :api, :success)

      {:ok, %HTTPoison.Response{status_code: status}} ->
        Logger.warning("[DataSourceHealth] API health check failed: status #{status}")
        record_result(state, :api, {:failure, "HTTP #{status}"})

      {:error, %HTTPoison.Error{reason: reason}} ->
        Logger.warning("[DataSourceHealth] API health check failed: #{inspect(reason)}")
        record_result(state, :api, {:failure, reason})
    end
  end

  defp check_subgraph_health(state) do
    case SubgraphClient.subgraph_healthy?() do
      {:ok, true} ->
        Logger.debug("[DataSourceHealth] Subgraph health check: OK")
        record_result(state, :subgraph, :success)

      {:ok, false} ->
        Logger.warning("[DataSourceHealth] Subgraph health check: syncing/unhealthy")
        record_result(state, :subgraph, {:failure, "syncing"})

      {:error, reason} ->
        Logger.warning("[DataSourceHealth] Subgraph health check failed: #{inspect(reason)}")
        record_result(state, :subgraph, {:failure, reason})
    end
  end

  defp record_result(state, :api, :success) do
    now = DateTime.utc_now()
    recent = [:success | state.api_recent_results] |> Enum.take(@recent_window)
    was_healthy = calculate_health(state.api_recent_results)
    is_healthy = calculate_health(recent)

    # Log health state transitions
    if !was_healthy and is_healthy do
      Logger.info("[DataSourceHealth] API recovered - now healthy (success rate: #{format_rate(recent)})")
    end

    %{state |
      api_status: :healthy,
      api_last_success: now,
      api_recent_results: recent
    }
  end

  defp record_result(state, :api, {:failure, reason}) do
    now = DateTime.utc_now()
    recent = [:failure | state.api_recent_results] |> Enum.take(@recent_window)
    was_healthy = calculate_health(state.api_recent_results)
    is_healthy = calculate_health(recent)

    # Log health state transitions
    if was_healthy and !is_healthy do
      Logger.warning("[DataSourceHealth] API degraded - now unhealthy (success rate: #{format_rate(recent)}, reason: #{inspect(reason)})")
    end

    %{state |
      api_status: :unhealthy,
      api_last_failure: now,
      api_recent_results: recent
    }
  end

  defp record_result(state, :subgraph, :success) do
    now = DateTime.utc_now()
    recent = [:success | state.subgraph_recent_results] |> Enum.take(@recent_window)
    was_healthy = calculate_health(state.subgraph_recent_results)
    is_healthy = calculate_health(recent)

    # Log health state transitions
    if !was_healthy and is_healthy do
      Logger.info("[DataSourceHealth] Subgraph recovered - now healthy (success rate: #{format_rate(recent)})")
    end

    %{state |
      subgraph_status: :healthy,
      subgraph_last_success: now,
      subgraph_recent_results: recent
    }
  end

  defp record_result(state, :subgraph, {:failure, reason}) do
    now = DateTime.utc_now()
    recent = [:failure | state.subgraph_recent_results] |> Enum.take(@recent_window)
    was_healthy = calculate_health(state.subgraph_recent_results)
    is_healthy = calculate_health(recent)

    # Log health state transitions
    if was_healthy and !is_healthy do
      Logger.warning("[DataSourceHealth] Subgraph degraded - now unhealthy (success rate: #{format_rate(recent)}, reason: #{inspect(reason)})")
    end

    %{state |
      subgraph_status: :unhealthy,
      subgraph_last_failure: now,
      subgraph_recent_results: recent
    }
  end

  defp format_rate(results) do
    rate = calculate_success_rate(results)
    "#{Float.round(rate * 100, 1)}%"
  end

  defp build_health_summary(state) do
    %{
      api: %{
        status: state.api_status,
        healthy: calculate_health(state.api_recent_results),
        success_rate: calculate_success_rate(state.api_recent_results),
        last_success: state.api_last_success,
        last_failure: state.api_last_failure
      },
      subgraph: %{
        status: state.subgraph_status,
        healthy: calculate_health(state.subgraph_recent_results),
        success_rate: calculate_success_rate(state.subgraph_recent_results),
        last_success: state.subgraph_last_success,
        last_failure: state.subgraph_last_failure
      },
      recommended_source: calculate_recommended_source(state),
      checked_at: DateTime.utc_now(),
      uptime_seconds: DateTime.diff(DateTime.utc_now(), state.started_at)
    }
  end

  defp calculate_health([]), do: true  # No data = assume healthy
  defp calculate_health(results) do
    calculate_success_rate(results) >= @healthy_threshold
  end

  defp calculate_success_rate([]), do: 1.0
  defp calculate_success_rate(results) do
    successes = Enum.count(results, &(&1 == :success))
    successes / length(results)
  end

  defp calculate_recommended_source(state) do
    api_healthy = calculate_health(state.api_recent_results)
    subgraph_healthy = calculate_health(state.subgraph_recent_results)

    cond do
      subgraph_healthy -> :subgraph
      api_healthy -> :api
      true -> :subgraph
    end
  end

  defp fallback_health_summary do
    %{
      api: %{status: :unknown, healthy: false, success_rate: 0.0, last_success: nil, last_failure: nil},
      subgraph: %{status: :unknown, healthy: true, success_rate: 1.0, last_success: nil, last_failure: nil},
      recommended_source: :subgraph,
      checked_at: DateTime.utc_now(),
      uptime_seconds: 0
    }
  end
end
