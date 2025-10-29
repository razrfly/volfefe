defmodule VolfefeMachineWeb.Router do
  use VolfefeMachineWeb, :router
  import Oban.Web.Router

  pipeline :browser do
    plug :accepts, ["html"]
    plug :fetch_session
    plug :fetch_live_flash
    plug :put_root_layout, html: {VolfefeMachineWeb.Layouts, :root}
    plug :protect_from_forgery
    plug :put_secure_browser_headers
  end

  pipeline :api do
    plug :accepts, ["json"]
  end

  scope "/", VolfefeMachineWeb do
    pipe_through :browser

    get "/", PageController, :home
  end

  # Admin interface
  scope "/admin", VolfefeMachineWeb.Admin do
    pipe_through :browser

    live "/content", ContentIndexLive, :index
    live "/content/:id", ContentIndexLive, :show
    live "/content/:id/analysis", ContentAnalysisLive, :show
    live "/ml", MLDashboardLive, :index
    live "/market-analysis", MarketAnalysisLive, :index
  end

  # Admin Oban dashboard
  # TODO: Add authentication in production! This is currently publicly accessible.
  # Recommended: Use Plug.BasicAuth or create an admin authentication pipeline.
  # Example:
  #   pipeline :admin do
  #     plug :browser
  #     plug :require_authenticated_admin
  #   end
  scope "/admin" do
    pipe_through :browser

    oban_dashboard "/oban"
  end

  # Other scopes may use custom stacks.
  # scope "/api", VolfefeMachineWeb do
  #   pipe_through :api
  # end

  # Enable LiveDashboard and Swoosh mailbox preview in development
  if Application.compile_env(:volfefe_machine, :dev_routes) do
    # If you want to use the LiveDashboard in production, you should put
    # it behind authentication and allow only admins to access it.
    # If your application does not have an admins-only section yet,
    # you can use Plug.BasicAuth to set up some basic authentication
    # as long as you are also using SSL (which you should anyway).
    import Phoenix.LiveDashboard.Router

    scope "/dev" do
      pipe_through :browser

      live_dashboard "/dashboard", metrics: VolfefeMachineWeb.Telemetry
      forward "/mailbox", Plug.Swoosh.MailboxPreview
    end
  end
end
