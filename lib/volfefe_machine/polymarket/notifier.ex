defmodule VolfefeMachine.Polymarket.Notifier do
  @moduledoc """
  Notification system for Polymarket insider trading alerts.

  Supports multiple notification channels:
  - Slack webhooks
  - Discord webhooks
  - Email (future)

  ## Configuration

      config :volfefe_machine, VolfefeMachine.Polymarket.Notifier,
        enabled: true,
        channels: [
          slack: [
            webhook_url: "https://hooks.slack.com/services/...",
            min_severity: "high"  # Only notify for high/critical
          ],
          discord: [
            webhook_url: "https://discord.com/api/webhooks/...",
            min_severity: "medium"
          ]
        ]

  ## Usage

      # Send notification for an alert
      Notifier.notify(alert)

      # Test webhook connectivity
      Notifier.test_webhook(:slack)
  """

  require Logger

  alias VolfefeMachine.Polymarket.Alert

  @severity_levels %{"low" => 1, "medium" => 2, "high" => 3, "critical" => 4}

  # ============================================
  # Public API
  # ============================================

  @doc """
  Send notifications for an alert to all configured channels.
  Returns a map of results per channel.
  """
  def notify(%Alert{} = alert) do
    if enabled?() do
      channels()
      |> Enum.map(fn {channel, config} ->
        result = if meets_severity_threshold?(alert, config) do
          send_notification(channel, alert, config)
        else
          {:skipped, :below_threshold}
        end
        {channel, result}
      end)
      |> Map.new()
    else
      %{all: {:skipped, :notifications_disabled}}
    end
  end

  @doc """
  Test webhook connectivity for a specific channel.
  Sends a test message to verify configuration.
  """
  def test_webhook(channel) do
    config = get_channel_config(channel)

    if config do
      test_alert = build_test_alert()
      send_notification(channel, test_alert, config)
    else
      {:error, :channel_not_configured}
    end
  end

  @doc """
  Check if notifications are enabled.
  """
  def enabled? do
    config()[:enabled] == true
  end

  @doc """
  Get configured notification channels.
  """
  def channels do
    config()[:channels] || []
  end

  @doc """
  Get configuration for a specific channel.
  """
  def get_channel_config(channel) do
    channels()[channel]
  end

  # ============================================
  # Channel Implementations
  # ============================================

  defp send_notification(:slack, alert, config) do
    webhook_url = config[:webhook_url]

    if webhook_url do
      payload = build_slack_payload(alert)
      post_webhook(webhook_url, payload, "Slack")
    else
      {:error, :no_webhook_url}
    end
  end

  defp send_notification(:discord, alert, config) do
    webhook_url = config[:webhook_url]

    if webhook_url do
      payload = build_discord_payload(alert)
      post_webhook(webhook_url, payload, "Discord")
    else
      {:error, :no_webhook_url}
    end
  end

  defp send_notification(channel, _alert, _config) do
    Logger.warning("Unknown notification channel: #{channel}")
    {:error, :unknown_channel}
  end

  # ============================================
  # Slack Formatting
  # ============================================

  defp build_slack_payload(alert) do
    severity_emoji = severity_emoji(alert.severity)
    color = severity_color(alert.severity)

    %{
      username: "Polymarket Insider Alert",
      icon_emoji: ":warning:",
      attachments: [
        %{
          color: color,
          blocks: [
            %{
              type: "header",
              text: %{
                type: "plain_text",
                text: "#{severity_emoji} #{String.upcase(alert.severity)} Alert: Suspicious Trade Detected",
                emoji: true
              }
            },
            %{
              type: "section",
              fields: [
                %{
                  type: "mrkdwn",
                  text: "*Wallet:*\n`#{format_wallet(alert.wallet_address)}`"
                },
                %{
                  type: "mrkdwn",
                  text: "*Insider Probability:*\n#{format_probability(alert.insider_probability)}"
                },
                %{
                  type: "mrkdwn",
                  text: "*Trade Size:*\n#{format_money(alert.trade_size)}"
                },
                %{
                  type: "mrkdwn",
                  text: "*Anomaly Score:*\n#{format_decimal(alert.anomaly_score)}"
                }
              ]
            },
            %{
              type: "section",
              text: %{
                type: "mrkdwn",
                text: "*Market:*\n#{alert.market_question || "Unknown"}"
              }
            },
            %{
              type: "context",
              elements: [
                %{
                  type: "mrkdwn",
                  text: "Alert ID: `#{alert.alert_id}` | Type: #{alert.alert_type} | #{format_time(alert.triggered_at)}"
                }
              ]
            }
          ]
        }
      ]
    }
  end

  # ============================================
  # Discord Formatting
  # ============================================

  defp build_discord_payload(alert) do
    severity_emoji = severity_emoji(alert.severity)
    color = severity_color_int(alert.severity)

    %{
      username: "Polymarket Insider Alert",
      embeds: [
        %{
          title: "#{severity_emoji} #{String.upcase(alert.severity)} Alert",
          description: "Suspicious trade detected",
          color: color,
          fields: [
            %{
              name: "Wallet",
              value: "`#{format_wallet(alert.wallet_address)}`",
              inline: true
            },
            %{
              name: "Insider Probability",
              value: format_probability(alert.insider_probability),
              inline: true
            },
            %{
              name: "Trade Size",
              value: format_money(alert.trade_size),
              inline: true
            },
            %{
              name: "Anomaly Score",
              value: format_decimal(alert.anomaly_score),
              inline: true
            },
            %{
              name: "Market",
              value: truncate(alert.market_question || "Unknown", 100),
              inline: false
            }
          ],
          footer: %{
            text: "Alert ID: #{alert.alert_id} | #{alert.alert_type}"
          },
          timestamp: format_iso8601(alert.triggered_at)
        }
      ]
    }
  end

  # ============================================
  # HTTP
  # ============================================

  defp post_webhook(url, payload, channel_name) do
    body = Jason.encode!(payload)

    headers = [
      {"Content-Type", "application/json"}
    ]

    case Req.post(url, body: body, headers: headers) do
      {:ok, %{status: status}} when status in 200..299 ->
        Logger.info("#{channel_name} notification sent successfully")
        {:ok, :sent}

      {:ok, %{status: status, body: body}} ->
        Logger.error("#{channel_name} webhook failed: status=#{status}, body=#{inspect(body)}")
        {:error, {:http_error, status}}

      {:error, reason} ->
        Logger.error("#{channel_name} webhook request failed: #{inspect(reason)}")
        {:error, reason}
    end
  end

  # ============================================
  # Helpers
  # ============================================

  defp config do
    Application.get_env(:volfefe_machine, __MODULE__, [])
  end

  defp meets_severity_threshold?(alert, config) do
    min_severity = config[:min_severity] || "low"
    alert_level = @severity_levels[alert.severity] || 0
    min_level = @severity_levels[min_severity] || 0
    alert_level >= min_level
  end

  defp build_test_alert do
    %Alert{
      alert_id: "test_#{System.system_time(:second)}",
      alert_type: "manual",
      severity: "medium",
      wallet_address: "0x0000000000000000000000000000000000000000",
      insider_probability: Decimal.new("0.75"),
      anomaly_score: Decimal.new("0.82"),
      trade_size: Decimal.new("5000.00"),
      market_question: "Test Alert - Webhook Connectivity Check",
      triggered_at: DateTime.utc_now()
    }
  end

  defp severity_emoji("critical"), do: "🚨"
  defp severity_emoji("high"), do: "⚠️"
  defp severity_emoji("medium"), do: "📊"
  defp severity_emoji("low"), do: "ℹ️"
  defp severity_emoji(_), do: "❓"

  defp severity_color("critical"), do: "#FF0000"
  defp severity_color("high"), do: "#FF9900"
  defp severity_color("medium"), do: "#FFCC00"
  defp severity_color("low"), do: "#36A64F"
  defp severity_color(_), do: "#808080"

  defp severity_color_int("critical"), do: 16_711_680  # Red
  defp severity_color_int("high"), do: 16_750_848     # Orange
  defp severity_color_int("medium"), do: 16_763_904   # Yellow
  defp severity_color_int("low"), do: 3_581_519      # Green
  defp severity_color_int(_), do: 8_421_504          # Gray

  defp format_wallet(nil), do: "Unknown"
  defp format_wallet(address) when byte_size(address) > 12 do
    "#{String.slice(address, 0, 6)}...#{String.slice(address, -4, 4)}"
  end
  defp format_wallet(address), do: address

  defp format_probability(nil), do: "N/A"
  defp format_probability(%Decimal{} = d) do
    pct = Decimal.mult(d, 100) |> Decimal.round(1)
    "#{pct}%"
  end
  defp format_probability(f) when is_float(f), do: "#{Float.round(f * 100, 1)}%"
  defp format_probability(n), do: "#{n}%"

  defp format_decimal(nil), do: "N/A"
  defp format_decimal(%Decimal{} = d), do: Decimal.round(d, 2) |> Decimal.to_string()
  defp format_decimal(n), do: "#{n}"

  defp format_money(nil), do: "$0"
  defp format_money(%Decimal{} = d) do
    "$#{Decimal.round(d, 2) |> Decimal.to_string(:normal)}"
  end
  defp format_money(n), do: "$#{n}"

  defp format_time(nil), do: "N/A"
  defp format_time(%DateTime{} = dt) do
    Calendar.strftime(dt, "%Y-%m-%d %H:%M:%S UTC")
  end

  defp format_iso8601(nil), do: nil
  defp format_iso8601(%DateTime{} = dt), do: DateTime.to_iso8601(dt)

  defp truncate(nil, _), do: ""
  defp truncate(str, max) when is_binary(str) do
    if String.length(str) > max do
      String.slice(str, 0, max - 3) <> "..."
    else
      str
    end
  end
end
