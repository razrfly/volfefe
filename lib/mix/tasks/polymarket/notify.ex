defmodule Mix.Tasks.Polymarket.Notify do
  @moduledoc """
  Manage and test notification channels for Polymarket alerts.

  ## Commands

      # Show notification status and configuration
      mix polymarket.notify

      # Test Slack webhook
      mix polymarket.notify --test slack

      # Test Discord webhook
      mix polymarket.notify --test discord

      # Test all channels
      mix polymarket.notify --test all

      # Send a manual notification for an alert
      mix polymarket.notify --alert ID

      # Enable notifications
      mix polymarket.notify --enable

      # Disable notifications
      mix polymarket.notify --disable

  ## Options

      --test CHANNEL    Test webhook connectivity (slack, discord, all)
      --alert ID        Send notification for specific alert by ID
      --enable          Enable notifications globally
      --disable         Disable notifications globally

  ## Configuration

      Webhook URLs should be set via environment variables:

      export SLACK_WEBHOOK_URL="https://hooks.slack.com/services/..."
      export DISCORD_WEBHOOK_URL="https://discord.com/api/webhooks/..."

      Or in config/runtime.exs:

      config :volfefe_machine, VolfefeMachine.Polymarket.Notifier,
        enabled: true,
        channels: [
          slack: [
            webhook_url: "https://hooks.slack.com/...",
            min_severity: "high"
          ]
        ]
  """

  use Mix.Task
  alias VolfefeMachine.Polymarket.Notifier
  alias VolfefeMachine.Polymarket.Alert
  alias VolfefeMachine.Repo

  @shortdoc "Manage notification channels for alerts"

  @impl Mix.Task
  def run(args) do
    Mix.Task.run("app.start")

    {opts, _, _} = OptionParser.parse(args,
      switches: [
        test: :string,
        alert: :integer,
        enable: :boolean,
        disable: :boolean
      ],
      aliases: [t: :test, a: :alert, e: :enable, d: :disable]
    )

    cond do
      opts[:test] ->
        test_channel(opts[:test])

      opts[:alert] ->
        send_alert_notification(opts[:alert])

      opts[:enable] ->
        enable_notifications()

      opts[:disable] ->
        disable_notifications()

      true ->
        show_status()
    end
  end

  # ============================================
  # Commands
  # ============================================

  defp show_status do
    print_header("NOTIFICATION STATUS")

    enabled = Notifier.enabled?()
    enabled_icon = if enabled, do: "🟢", else: "🔴"

    Mix.shell().info("#{enabled_icon} Notifications: #{if enabled, do: "ENABLED", else: "DISABLED"}")
    Mix.shell().info("")

    channels = Notifier.channels()

    if Enum.empty?(channels) do
      Mix.shell().info("No channels configured.")
    else
      Mix.shell().info("Configured Channels:")
      Mix.shell().info("")

      Enum.each(channels, fn {channel, config} ->
        webhook_url = config[:webhook_url]
        min_severity = config[:min_severity] || "low"

        status = if webhook_url && webhook_url != "", do: "✅ Configured", else: "❌ No webhook URL"

        Mix.shell().info("  #{channel_icon(channel)} #{String.capitalize(to_string(channel))}")
        Mix.shell().info("     Status: #{status}")
        Mix.shell().info("     Min Severity: #{min_severity}")

        if webhook_url && webhook_url != "" do
          # Show masked URL
          masked = mask_webhook_url(webhook_url)
          Mix.shell().info("     Webhook: #{masked}")
        end

        Mix.shell().info("")
      end)
    end

    print_divider()
    Mix.shell().info("Commands:")
    Mix.shell().info("  mix polymarket.notify --test slack    # Test Slack webhook")
    Mix.shell().info("  mix polymarket.notify --test discord  # Test Discord webhook")
    Mix.shell().info("  mix polymarket.notify --enable        # Enable notifications")
    Mix.shell().info("")
  end

  defp test_channel("all") do
    print_header("TESTING ALL CHANNELS")

    channels = Notifier.channels()

    if Enum.empty?(channels) do
      Mix.shell().error("No channels configured.")
    else
      Enum.each(channels, fn {channel, _config} ->
        test_single_channel(channel)
        Mix.shell().info("")
      end)
    end
  end

  defp test_channel(channel_str) do
    channel = String.to_existing_atom(channel_str)
    test_single_channel(channel)
  rescue
    ArgumentError ->
      Mix.shell().error("❌ Unknown channel: #{channel_str}")
      Mix.shell().info("   Valid channels: slack, discord")
  end

  defp test_single_channel(channel) do
    Mix.shell().info("#{channel_icon(channel)} Testing #{channel} webhook...")

    case Notifier.test_webhook(channel) do
      {:ok, :sent} ->
        Mix.shell().info("✅ Test notification sent successfully!")

      {:error, :channel_not_configured} ->
        Mix.shell().error("❌ Channel not configured. Set the webhook URL in config.")

      {:error, :no_webhook_url} ->
        Mix.shell().error("❌ No webhook URL configured for #{channel}.")
        Mix.shell().info("")
        Mix.shell().info("Set the webhook URL:")
        Mix.shell().info("  export #{env_var_name(channel)}=\"https://...\"")

      {:error, {:http_error, status}} ->
        Mix.shell().error("❌ Webhook returned HTTP #{status}. Check your webhook URL.")

      {:error, reason} ->
        Mix.shell().error("❌ Failed to send: #{inspect(reason)}")
    end
  end

  defp send_alert_notification(alert_id) do
    case Repo.get(Alert, alert_id) do
      nil ->
        Mix.shell().error("Alert ##{alert_id} not found.")

      alert ->
        Mix.shell().info("Sending notifications for Alert ##{alert_id}...")

        results = Notifier.notify(alert)

        Enum.each(results, fn {channel, result} ->
          case result do
            {:ok, :sent} ->
              Mix.shell().info("  ✅ #{channel}: Sent")

            {:skipped, reason} ->
              Mix.shell().info("  ⏭️  #{channel}: Skipped (#{reason})")

            {:error, reason} ->
              Mix.shell().error("  ❌ #{channel}: Failed (#{inspect(reason)})")
          end
        end)
    end
  end

  defp enable_notifications do
    Mix.shell().info("")
    Mix.shell().info("⚠️  To enable notifications, update your config:")
    Mix.shell().info("")
    Mix.shell().info("  1. Set environment variables:")
    Mix.shell().info("     export SLACK_WEBHOOK_URL=\"https://hooks.slack.com/services/...\"")
    Mix.shell().info("     export DISCORD_WEBHOOK_URL=\"https://discord.com/api/webhooks/...\"")
    Mix.shell().info("")
    Mix.shell().info("  2. Update config/runtime.exs:")
    Mix.shell().info("     config :volfefe_machine, VolfefeMachine.Polymarket.Notifier,")
    Mix.shell().info("       enabled: true")
    Mix.shell().info("")
    Mix.shell().info("  3. Restart the application")
    Mix.shell().info("")
  end

  defp disable_notifications do
    Mix.shell().info("")
    Mix.shell().info("To disable notifications, update config/runtime.exs:")
    Mix.shell().info("")
    Mix.shell().info("  config :volfefe_machine, VolfefeMachine.Polymarket.Notifier,")
    Mix.shell().info("    enabled: false")
    Mix.shell().info("")
    Mix.shell().info("Then restart the application.")
    Mix.shell().info("")
  end

  # ============================================
  # Helpers
  # ============================================

  defp print_header(title) do
    Mix.shell().info("")
    Mix.shell().info(String.duplicate("═", 60))
    Mix.shell().info(title)
    Mix.shell().info(String.duplicate("═", 60))
    Mix.shell().info("")
  end

  defp print_divider do
    Mix.shell().info(String.duplicate("─", 60))
  end

  defp channel_icon(:slack), do: "💬"
  defp channel_icon(:discord), do: "🎮"
  defp channel_icon(:email), do: "📧"
  defp channel_icon(_), do: "📢"

  defp env_var_name(:slack), do: "SLACK_WEBHOOK_URL"
  defp env_var_name(:discord), do: "DISCORD_WEBHOOK_URL"
  defp env_var_name(channel), do: "#{String.upcase(to_string(channel))}_WEBHOOK_URL"

  defp mask_webhook_url(nil), do: "Not set"
  defp mask_webhook_url(""), do: "Not set"
  defp mask_webhook_url(url) do
    case URI.parse(url) do
      %{host: host, path: path} when not is_nil(path) ->
        # Show host and first/last parts of path
        path_parts = String.split(path, "/") |> Enum.reject(&(&1 == ""))
        masked_path = case path_parts do
          [] -> ""
          [single] -> "/#{String.slice(single, 0, 4)}..."
          parts ->
            first = List.first(parts)
            last = List.last(parts)
            "/#{first}/...#{String.slice(last, -4, 4)}"
        end
        "#{host}#{masked_path}"

      _ ->
        "****"
    end
  end
end
