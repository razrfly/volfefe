defmodule VolfefeMachine.Application do
  # See https://hexdocs.pm/elixir/Application.html
  # for more information on OTP Applications
  @moduledoc false

  use Application

  @impl true
  def start(_type, _args) do
    children = [
      VolfefeMachineWeb.Telemetry,
      VolfefeMachine.Repo,
      {DNSCluster, query: Application.get_env(:volfefe_machine, :dns_cluster_query) || :ignore},
      {Phoenix.PubSub, name: VolfefeMachine.PubSub},
      # Start a worker by calling: VolfefeMachine.Worker.start_link(arg)
      # {VolfefeMachine.Worker, arg},
      # Start to serve requests, typically the last entry
      VolfefeMachineWeb.Endpoint
    ]

    # See https://hexdocs.pm/elixir/Supervisor.html
    # for other strategies and supported options
    opts = [strategy: :one_for_one, name: VolfefeMachine.Supervisor]
    Supervisor.start_link(children, opts)
  end

  # Tell Phoenix to update the endpoint configuration
  # whenever the application is updated.
  @impl true
  def config_change(changed, _new, removed) do
    VolfefeMachineWeb.Endpoint.config_change(changed, removed)
    :ok
  end
end
