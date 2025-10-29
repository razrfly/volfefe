defmodule VolfefeMachineWeb.Admin.ContentAnalysisLive do
  @moduledoc """
  Detailed market impact analysis page for individual content items.

  Shows comprehensive visualization and statistical analysis of how markets
  reacted to Trump posts across multiple assets and time windows.
  """

  use VolfefeMachineWeb, :live_view

  alias VolfefeMachine.{Content, MarketData}

  @impl true
  def mount(%{"id" => id_str}, _session, socket) do
    case Integer.parse(id_str) do
      {id, ""} ->
        case load_content_and_analysis(id) do
          {:ok, data} ->
            {:ok,
             socket
             |> assign(:page_title, "Market Analysis - Content ##{id}")
             |> assign(:content_id, id)
             |> assign(:content, data.content)
             |> assign(:snapshots, data.snapshots)
             |> assign(:impact_summary, data.impact_summary)
             |> assign(:chart_data, data.chart_data)
             |> assign(:selected_assets, ["SPY", "QQQ", "DIA", "VXX", "GLD"])
             |> assign(:time_window, :all)}

          {:error, reason} ->
            {:ok,
             socket
             |> put_flash(:error, format_error(reason))
             |> assign(:page_title, "Market Analysis")
             |> assign(:content_id, id)
             |> assign(:content, nil)
             |> assign(:snapshots, [])
             |> assign(:impact_summary, nil)
             |> assign(:chart_data, nil)}
        end

      _ ->
        {:ok,
         socket
         |> put_flash(:error, "Invalid content ID")
         |> assign(:page_title, "Market Analysis")
         |> assign(:content, nil)}
    end
  end

  @impl true
  def handle_params(_params, _url, socket) do
    {:noreply, socket}
  end

  @impl true
  def handle_event("toggle_asset", %{"asset" => asset}, socket) do
    selected = socket.assigns.selected_assets

    updated_selected =
      if asset in selected do
        List.delete(selected, asset)
      else
        [asset | selected]
      end

    {:noreply, assign(socket, :selected_assets, updated_selected)}
  end

  # Private functions

  defp load_content_and_analysis(content_id) do
    case Content.get_content(content_id) do
      nil ->
        {:error, :content_not_found}

      content ->
        # Get snapshots
        snapshots_result = MarketData.get_content_snapshots(content_id)
        impact_result = MarketData.get_impact_summary(content_id)

        case {snapshots_result, impact_result} do
          {{:ok, snapshots}, {:ok, impact_summary}} ->
            chart_data = prepare_chart_data(snapshots)

            {:ok, %{
              content: content,
              snapshots: snapshots,
              impact_summary: impact_summary,
              chart_data: chart_data
            }}

          {{:error, :no_snapshots}, _} ->
            {:error, :no_snapshots}

          {_, {:error, :no_snapshots}} ->
            {:error, :no_snapshots}

          _ ->
            {:error, :unknown_error}
        end
    end
  end

  defp prepare_chart_data(snapshots) do
    %{
      time_series: prepare_time_series(snapshots),
      assets: prepare_asset_summaries(snapshots)
    }
  end

  defp prepare_time_series(snapshots) do
    # Snapshots come as a list of %{asset: asset, snapshots: %{"window" => snapshot, ...}}
    # We need to transform this into a list per asset with data points ordered by window
    window_order = %{"before" => 0, "1hr_after" => 1, "4hr_after" => 2, "24hr_after" => 3}
    windows = ["before", "1hr_after", "4hr_after", "24hr_after"]

    snapshots
    |> Enum.map(fn %{asset: asset, snapshots: asset_snapshots} ->
      # Create data points for each window in order
      data_points =
        windows
        |> Enum.map(fn window ->
          snapshot = Map.get(asset_snapshots, window)

          if snapshot do
            %{
              window: window,
              price_change: if(snapshot.price_change_pct, do: Decimal.to_float(snapshot.price_change_pct), else: 0.0),
              z_score: if(snapshot.z_score, do: Decimal.to_float(snapshot.z_score), else: 0.0),
              significance: snapshot.significance_level,
              market_state: snapshot.market_state
            }
          else
            # Missing snapshot - use zero values
            %{
              window: window,
              price_change: 0.0,
              z_score: 0.0,
              significance: nil,
              market_state: nil
            }
          end
        end)

      %{
        symbol: asset.symbol,
        data: data_points
      }
    end)
  end

  defp prepare_asset_summaries(snapshots) do
    snapshots
    |> Enum.map(fn %{asset: asset, snapshots: asset_snapshots} ->
      # Find max impact across all windows
      max_impact_snapshot =
        asset_snapshots
        |> Map.values()
        |> Enum.reject(&is_nil(&1.price_change_pct))
        |> Enum.max_by(
          fn s -> abs(Decimal.to_float(s.price_change_pct)) end,
          fn -> nil end
        )

      if max_impact_snapshot do
        %{
          symbol: asset.symbol,
          name: asset.name,
          max_window: max_impact_snapshot.window_type,
          max_price_change: Decimal.to_float(max_impact_snapshot.price_change_pct),
          max_z_score: if(max_impact_snapshot.z_score, do: Decimal.to_float(max_impact_snapshot.z_score), else: 0.0),
          significance: max_impact_snapshot.significance_level,
          volume_change: calculate_volume_change(asset_snapshots),
          market_state: max_impact_snapshot.market_state
        }
      else
        %{
          symbol: asset.symbol,
          name: asset.name,
          max_window: nil,
          max_price_change: 0.0,
          max_z_score: 0.0,
          significance: "noise",
          volume_change: 0.0,
          market_state: "unknown"
        }
      end
    end)
  end

  defp calculate_volume_change(snapshots) do
    # Find volume change from before to peak window
    before = Map.get(snapshots, "before")

    if before && before.volume do
      snapshots
      |> Map.values()
      |> Enum.reject(&(&1.window_type == "before"))
      |> Enum.reject(&is_nil(&1.volume))
      |> Enum.map(fn s ->
        ((s.volume - before.volume) / before.volume) * 100
      end)
      |> Enum.max(fn -> 0.0 end)
    else
      0.0
    end
  end

  defp format_error(:content_not_found), do: "Content not found"
  defp format_error(:no_snapshots), do: "No market snapshots available for this content"
  defp format_error(_), do: "An error occurred loading the analysis"

  # Template helpers

  def format_percentage(nil), do: "—"
  def format_percentage(0.0), do: "0.00%"

  def format_percentage(value) when is_float(value) do
    sign = if value >= 0, do: "+", else: ""
    "#{sign}#{:erlang.float_to_binary(value, decimals: 2)}%"
  end

  def format_z_score(nil), do: "—"
  def format_z_score(0.0), do: "0.00"

  def format_z_score(value) when is_float(value) do
    :erlang.float_to_binary(abs(value), decimals: 2) <> "σ"
  end

  def overall_impact_level(impact_summary) when is_nil(impact_summary), do: "UNKNOWN"

  def overall_impact_level(impact_summary) do
    case impact_summary.impact_level do
      "high" -> "HIGH"
      "moderate" -> "MODERATE"
      "low" -> "LOW"
      _ -> "MINIMAL"
    end
  end

  def impact_emoji("high"), do: "🚨"
  def impact_emoji("moderate"), do: "⚡"
  def impact_emoji("low"), do: "📊"
  def impact_emoji(_), do: "📉"

  def significance_badge_class("high"), do: "bg-red-100 text-red-800 border-red-300"
  def significance_badge_class("moderate"), do: "bg-yellow-100 text-yellow-800 border-yellow-300"
  def significance_badge_class("noise"), do: "bg-gray-100 text-gray-600 border-gray-300"
  def significance_badge_class(_), do: "bg-gray-100 text-gray-600 border-gray-300"

  def sentiment_badge_class("positive"), do: "bg-green-100 text-green-800"
  def sentiment_badge_class("negative"), do: "bg-red-100 text-red-800"
  def sentiment_badge_class("neutral"), do: "bg-gray-100 text-gray-800"
  def sentiment_badge_class(_), do: "bg-gray-100 text-gray-800"

  def price_change_class(value) when is_float(value) and value > 0, do: "text-green-600"
  def price_change_class(value) when is_float(value) and value < 0, do: "text-red-600"
  def price_change_class(_), do: "text-gray-600"

  def window_label("before"), do: "Before"
  def window_label("1hr_after"), do: "1hr After"
  def window_label("4hr_after"), do: "4hr After"
  def window_label("24hr_after"), do: "24hr After"
  def window_label(window), do: window

  def asset_icon("SPY"), do: "📈"
  def asset_icon("QQQ"), do: "📊"
  def asset_icon("DIA"), do: "🏭"
  def asset_icon("VXX"), do: "⚡"
  def asset_icon("GLD"), do: "💎"
  def asset_icon(_), do: "📉"

  # SVG Chart Rendering

  def render_time_series_chart(time_series_data, selected_assets) do
    # Filter to only selected assets
    filtered_data =
      time_series_data
      |> Enum.filter(fn asset -> asset.symbol in selected_assets end)

    if length(filtered_data) == 0 do
      assigns = %{}
      ~H"""
      <div class="text-center py-12 text-gray-500">
        <p>Select at least one asset to display the chart</p>
      </div>
      """
    else
      # Chart dimensions
      width = 800
      height = 400
      padding = %{top: 20, right: 100, bottom: 50, left: 60}

      chart_width = width - padding.left - padding.right
      chart_height = height - padding.top - padding.bottom

      # Get all price changes to determine Y-axis range
      all_values =
        filtered_data
        |> Enum.flat_map(fn asset -> Enum.map(asset.data, & &1.price_change) end)

      y_max = Enum.max(all_values ++ [2.0]) |> ceil()
      y_min = Enum.min(all_values ++ [-2.0]) |> floor()

      # X-axis positions for 4 windows
      window_positions = %{
        "before" => 0,
        "1hr_after" => 1,
        "4hr_after" => 2,
        "24hr_after" => 3
      }

      x_scale = chart_width / 3  # 3 intervals between 4 points

      # Color scheme for assets
      asset_colors = %{
        "SPY" => "#3b82f6",   # Blue
        "QQQ" => "#10b981",   # Green
        "DIA" => "#f59e0b",   # Amber
        "VXX" => "#ef4444",   # Red
        "GLD" => "#8b5cf6"    # Purple
      }

      assigns = %{
        width: width,
        height: height,
        padding: padding,
        chart_width: chart_width,
        chart_height: chart_height,
        y_max: y_max,
        y_min: y_min,
        y_range: y_max - y_min,
        x_scale: x_scale,
        filtered_data: filtered_data,
        window_positions: window_positions,
        asset_colors: asset_colors
      }

      ~H"""
      <svg width="100%" viewBox={"0 0 #{@width} #{@height}"} class="font-sans">
        <!-- Background -->
        <rect width={@width} height={@height} fill="white"/>

        <!-- Y-axis grid lines and significance bands -->
        <g transform={"translate(#{@padding.left}, #{@padding.top})"}>
          <!-- ±2σ band (high significance) -->
          <%= if @y_max >= 2.0 and @y_min <= -2.0 do %>
            <rect
              x="0"
              y={scale_y(2.0, @y_min, @y_range, @chart_height)}
              width={@chart_width}
              height={scale_y(-2.0, @y_min, @y_range, @chart_height) - scale_y(2.0, @y_min, @y_range, @chart_height)}
              fill="#fee2e2"
              opacity="0.3"
            />
          <% end %>

          <!-- ±1σ band (moderate significance) -->
          <%= if @y_max >= 1.0 and @y_min <= -1.0 do %>
            <rect
              x="0"
              y={scale_y(1.0, @y_min, @y_range, @chart_height)}
              width={@chart_width}
              height={scale_y(-1.0, @y_min, @y_range, @chart_height) - scale_y(1.0, @y_min, @y_range, @chart_height)}
              fill="#fef3c7"
              opacity="0.3"
            />
          <% end %>

          <!-- Y-axis zero line -->
          <line
            x1="0"
            y1={scale_y(0, @y_min, @y_range, @chart_height)}
            x2={@chart_width}
            y2={scale_y(0, @y_min, @y_range, @chart_height)}
            stroke="#d1d5db"
            stroke-width="2"
          />

          <!-- Y-axis labels -->
          <%= for y <- Enum.to_list(@y_min..@y_max) do %>
            <text
              x="-10"
              y={scale_y(y, @y_min, @y_range, @chart_height)}
              text-anchor="end"
              dominant-baseline="middle"
              class="text-xs fill-gray-600"
            >
              <%= y %>%
            </text>
          <% end %>

          <!-- X-axis labels -->
          <%= for {window, position} <- @window_positions do %>
            <text
              x={position * @x_scale}
              y={@chart_height + 25}
              text-anchor="middle"
              class="text-sm fill-gray-700 font-medium"
            >
              <%= window_label(window) %>
            </text>
          <% end %>

          <!-- Plot lines for each asset -->
          <%= for asset <- @filtered_data do %>
            <%
              color = Map.get(@asset_colors, asset.symbol, "#6b7280")
              points =
                asset.data
                |> Enum.map(fn point ->
                  x = Map.get(@window_positions, point.window, 0) * @x_scale
                  y = scale_y(point.price_change, @y_min, @y_range, @chart_height)
                  {x, y, point}
                end)

              line_path =
                points
                |> Enum.map(fn {x, y, _} -> "#{x},#{y}" end)
                |> Enum.join(" ")
            %>

            <!-- Line -->
            <polyline
              points={line_path}
              fill="none"
              stroke={color}
              stroke-width="2.5"
              stroke-linejoin="round"
            />

            <!-- Points -->
            <%= for {x, y, point} <- points do %>
              <%
                point_size = case point.significance do
                  "high" -> 6
                  "moderate" -> 5
                  _ -> 4
                end
              %>
              <circle
                cx={x}
                cy={y}
                r={point_size}
                fill={color}
                stroke="white"
                stroke-width="2"
              >
                <title>
                  <%= asset.symbol %> - <%= window_label(point.window) %>
                  Price Change: <%= format_percentage(point.price_change) %>
                  Z-Score: <%= format_z_score(point.z_score) %>
                  Significance: <%= point.significance || "noise" %>
                </title>
              </circle>
            <% end %>

            <!-- Legend label -->
            <text
              x={@chart_width + 15}
              y={scale_y(List.last(asset.data).price_change, @y_min, @y_range, @chart_height)}
              class="text-sm font-medium"
              fill={color}
              dominant-baseline="middle"
            >
              <%= asset.symbol %>
            </text>
          <% end %>
        </g>

        <!-- Y-axis label -->
        <text
          x="15"
          y={@height / 2}
          transform={"rotate(-90, 15, #{@height / 2})"}
          text-anchor="middle"
          class="text-sm fill-gray-600 font-medium"
        >
          Price Change (%)
        </text>
      </svg>
      """
    end
  end

  defp scale_y(value, y_min, y_range, chart_height) do
    # Invert Y-axis (SVG Y grows downward)
    chart_height - ((value - y_min) / y_range * chart_height)
  end
end
