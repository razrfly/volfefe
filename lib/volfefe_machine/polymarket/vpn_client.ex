defmodule VolfefeMachine.Polymarket.VpnClient do
  @moduledoc """
  HTTP client wrapper that routes requests through VPN proxy when enabled.

  Polymarket geo-blocks US IP addresses for CLOB and Gamma APIs.
  This module provides proxy-aware HTTP functions that route through
  a local Gluetun VPN container when VPN_PROXY_ENABLED=true.

  ## Configuration

  Set these environment variables:
  - VPN_PROXY_ENABLED: "true" to enable proxy routing
  - VPN_PROXY_HOST: Proxy host (default: "localhost")
  - VPN_PROXY_PORT: Proxy port (default: "8888")

  ## Usage

      # Simple GET request (uses proxy if enabled)
      VpnClient.get("https://gamma-api.polymarket.com/markets")

      # With options
      VpnClient.get(url, receive_timeout: 30_000)

      # POST request
      VpnClient.post(url, json: %{foo: "bar"})

  ## VPN Setup

  Run Gluetun container:

      docker compose -f docker-compose.vpn.yml up -d

  """

  require Logger

  @default_timeout 30_000

  @doc """
  Returns the current VPN proxy configuration.
  """
  def config do
    Application.get_env(:volfefe_machine, :vpn_proxy, [])
  end

  @doc """
  Returns true if VPN proxy is enabled.
  """
  def enabled? do
    config()[:enabled] == true
  end

  @doc """
  Returns proxy options for Req if VPN is enabled, empty list otherwise.
  """
  def proxy_opts do
    if enabled?() do
      host = config()[:host] || "localhost"
      port = config()[:port] || 8888
      [connect_options: [proxy: {:http, host, port, []}]]
    else
      []
    end
  end

  @doc """
  Performs a GET request, routing through VPN proxy if enabled.

  ## Options

  All standard Req options are supported, plus:
  - :use_vpn - Override VPN setting (true/false), defaults to config

  ## Examples

      VpnClient.get("https://gamma-api.polymarket.com/markets")
      VpnClient.get(url, receive_timeout: 60_000)
      VpnClient.get(url, use_vpn: false)  # Force direct connection

  """
  def get(url, opts \\ []) do
    {use_vpn, req_opts} = Keyword.pop(opts, :use_vpn, enabled?())

    merged_opts =
      [receive_timeout: @default_timeout]
      |> Keyword.merge(req_opts)
      |> maybe_add_proxy(use_vpn)

    log_request(:get, url, use_vpn)
    Req.get(url, merged_opts)
  end

  @doc """
  Performs a POST request, routing through VPN proxy if enabled.
  """
  def post(url, opts \\ []) do
    {use_vpn, req_opts} = Keyword.pop(opts, :use_vpn, enabled?())

    merged_opts =
      [receive_timeout: @default_timeout]
      |> Keyword.merge(req_opts)
      |> maybe_add_proxy(use_vpn)

    log_request(:post, url, use_vpn)
    Req.post(url, merged_opts)
  end

  @doc """
  Checks if the VPN proxy is healthy and responding.

  Returns {:ok, %{ip: external_ip, country: country}} on success.
  """
  def health_check do
    if not enabled?() do
      {:error, :vpn_disabled}
    else
      # Use ifconfig.me to verify external IP through proxy
      case get("https://ifconfig.me/all.json", receive_timeout: 10_000) do
        {:ok, %{status: 200, body: body}} when is_map(body) ->
          {:ok, %{
            ip: body["ip_addr"],
            country: body["country"],
            via_proxy: true
          }}

        {:ok, %{status: status}} ->
          {:error, {:http_error, status}}

        {:error, reason} ->
          {:error, reason}
      end
    end
  end

  @doc """
  Returns status information about the VPN proxy configuration.
  """
  def status do
    cfg = config()

    %{
      enabled: cfg[:enabled] || false,
      host: cfg[:host] || "localhost",
      port: cfg[:port] || 8888,
      health: if(cfg[:enabled], do: health_check(), else: :disabled)
    }
  end

  # Private functions

  defp maybe_add_proxy(opts, true) do
    host = config()[:host] || "localhost"
    port = config()[:port] || 8888
    Keyword.put(opts, :connect_options, [proxy: {:http, host, port, []}])
  end

  defp maybe_add_proxy(opts, false), do: opts

  defp log_request(method, url, use_vpn) do
    uri = URI.parse(url)
    proxy_status = if use_vpn, do: "via VPN proxy", else: "direct"

    Logger.debug("[VpnClient] #{String.upcase(to_string(method))} #{uri.host}#{uri.path} (#{proxy_status})")
  end
end
