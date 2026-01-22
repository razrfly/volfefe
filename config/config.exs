# This file is responsible for configuring your application
# and its dependencies with the aid of the Config module.
#
# This configuration file is loaded before any dependency and
# is restricted to this project.

# General application configuration
import Config

config :volfefe_machine,
  ecto_repos: [VolfefeMachine.Repo],
  generators: [timestamp_type: :utc_datetime]

# Configures the endpoint
config :volfefe_machine, VolfefeMachineWeb.Endpoint,
  url: [host: "localhost"],
  adapter: Bandit.PhoenixAdapter,
  render_errors: [
    formats: [html: VolfefeMachineWeb.ErrorHTML, json: VolfefeMachineWeb.ErrorJSON],
    layout: false
  ],
  pubsub_server: VolfefeMachine.PubSub,
  live_view: [signing_salt: "sKuXb0/z"]

# Configures the mailer
#
# By default it uses the "Local" adapter which stores the emails
# locally. You can see the emails in your browser, at "/dev/mailbox".
#
# For production it's recommended to configure a different adapter
# at the `config/runtime.exs`.
config :volfefe_machine, VolfefeMachine.Mailer, adapter: Swoosh.Adapters.Local

# Configure esbuild (the version is required)
config :esbuild,
  version: "0.25.4",
  volfefe_machine: [
    args:
      ~w(js/app.js --bundle --target=es2022 --outdir=../priv/static/assets/js --external:/fonts/* --external:/images/* --alias:@=.),
    cd: Path.expand("../assets", __DIR__),
    env: %{"NODE_PATH" => [Path.expand("../deps", __DIR__), Mix.Project.build_path()]}
  ]

# Configure tailwind (the version is required)
config :tailwind,
  version: "4.1.7",
  volfefe_machine: [
    args: ~w(
      --input=assets/css/app.css
      --output=priv/static/assets/css/app.css
    ),
    cd: Path.expand("..", __DIR__)
  ]

# Configures Elixir's Logger
config :logger, :default_formatter,
  format: "$time $metadata[$level] $message\n",
  metadata: [:request_id]

# Use Jason for JSON parsing in Phoenix
config :phoenix, :json_library, Jason

# Configure Oban for background job processing
config :volfefe_machine, Oban,
  engine: Oban.Engines.Basic,
  repo: VolfefeMachine.Repo,
  queues: [
    ml_sentiment: 10,
    ml_ner: 10,
    ml_batch: 5,
    market_baselines: 3,
    market_snapshots: 5,
    market_batch: 2,
    content_import: 2,
    polymarket: 5
  ],
  plugins: [
    {Oban.Plugins.Pruner, max_age: 60 * 60 * 24 * 7},
    {Oban.Plugins.Lifeline, rescue_after: :timer.minutes(30)},
    {Oban.Plugins.Cron,
     crontab: [
       # Trade ingestion every 5 minutes - wide net coverage
       {"*/5 * * * *", VolfefeMachine.Workers.Polymarket.TradeIngestionWorker},
       # Market sync hourly with resolution checking
       {"0 * * * *", VolfefeMachine.Workers.Polymarket.MarketSyncWorker, args: %{check_resolutions: true}},
       # Diversity check every 30 minutes - coverage health monitoring
       {"*/30 * * * *", VolfefeMachine.Workers.Polymarket.DiversityCheckWorker}
     ]}
  ]

# Configure LiveToast for toast notifications
config :live_toast,
  duration: 4000,
  max_toasts: 5,
  kinds: [:info, :error, :success, :warning]

# Configure Trade Monitor for real-time insider detection
# Disabled by default - enable via mix polymarket.monitor --enable
config :volfefe_machine, VolfefeMachine.Polymarket.TradeMonitor,
  poll_interval: 30_000,        # 30 seconds between polls
  anomaly_threshold: 0.7,       # Min anomaly score to trigger alert
  probability_threshold: 0.5,   # Min insider probability to trigger alert
  enabled: false                # Disabled by default, enable via CLI

# Configure Notifier for external alert notifications
# Set webhook URLs in runtime.exs or environment variables
config :volfefe_machine, VolfefeMachine.Polymarket.Notifier,
  enabled: false,               # Enable when webhook URLs are configured
  channels: [
    slack: [
      webhook_url: System.get_env("SLACK_WEBHOOK_URL"),
      min_severity: "high"      # Only high/critical alerts
    ],
    discord: [
      webhook_url: System.get_env("DISCORD_WEBHOOK_URL"),
      min_severity: "medium"    # medium and above
    ]
  ]

# Import ML models configuration
import_config "ml_models.exs"

# Import environment specific config. This must remain at the bottom
# of this file so it overrides the configuration defined above.
import_config "#{config_env()}.exs"
