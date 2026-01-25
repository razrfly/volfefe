defmodule VolfefeMachineWeb.CatalystComponents do
  @moduledoc """
  Authentic Catalyst UI components based on Tailwind Plus UI Kit.

  These components provide a minimal, zinc-based professional look following
  the actual Catalyst design system patterns.

  ## Usage

      use VolfefeMachineWeb, :html
      import VolfefeMachineWeb.CatalystComponents

  ## Components

  - `badge/1` - Status indicators (zinc, red, amber, green)
  - `catalyst_button/1` - Styled buttons (solid, outline, plain)
  - `heading/1` - Page headings
  - `subheading/1` - Section subheadings
  - `stat_card/1` - Metric display cards
  - `data_table/1` - Professional data tables
  - `description_list/1` - Key-value pair displays
  - `divider/1` - Visual separators
  - `alert_banner/1` - Notification banners
  - `tabs/1` - Tab navigation
  - `empty_state/1` - Empty state placeholders

  ## Color Palette (Minimal Catalyst Style)

  Badge colors: zinc (default), red (critical), amber (warning), green (success)
  Button colors: dark (primary), zinc (secondary), outline, plain

  ## Note on Layout

  This module intentionally does NOT include sidebar layout components.
  The Polymarket dashboard uses horizontal tab navigation with admin_nav
  to preserve navigation to other admin pages (Content, ML Jobs).
  """

  use Phoenix.Component

  # ============================================
  # Badge Component
  # ============================================

  @badge_colors %{
    zinc: "bg-zinc-600/10 text-zinc-700 dark:bg-white/5 dark:text-zinc-400",
    red: "bg-red-500/15 text-red-700 dark:bg-red-500/10 dark:text-red-400",
    amber: "bg-amber-400/20 text-amber-700 dark:bg-amber-400/10 dark:text-amber-400",
    green: "bg-green-500/15 text-green-700 dark:bg-green-500/10 dark:text-green-400"
  }

  @doc """
  Renders a badge with color variants.

  ## Examples

      <.badge>Default</.badge>
      <.badge color={:green}>Active</.badge>
      <.badge color={:red}>Critical</.badge>

  ## Attributes

  - `color` - Badge color: :zinc (default), :red, :amber, :green
  - `class` - Additional CSS classes
  """
  attr :color, :atom, default: :zinc, values: [:zinc, :red, :amber, :green]
  attr :class, :string, default: nil
  attr :rest, :global

  slot :inner_block, required: true

  def badge(assigns) do
    color_class = @badge_colors[assigns.color]
    assigns = assign(assigns, :color_class, color_class)

    ~H"""
    <span
      class={[
        "inline-flex items-center gap-x-1.5 rounded px-1.5 py-0.5 text-sm font-medium sm:text-xs",
        @color_class,
        @class
      ]}
      {@rest}
    >
      {render_slot(@inner_block)}
    </span>
    """
  end

  # ============================================
  # Button Component
  # ============================================

  @button_base "relative isolate inline-flex items-center justify-center gap-x-2 rounded border text-base font-semibold px-3.5 py-2.5 sm:px-3 sm:py-1.5 sm:text-sm focus:outline-none focus:ring-2 focus:ring-offset-2 focus:ring-zinc-400 dark:focus:ring-zinc-500 dark:focus:ring-offset-zinc-900 disabled:opacity-50"

  @button_solid_colors %{
    dark: "text-white bg-zinc-900 border-zinc-950/90 hover:bg-zinc-800 shadow-sm dark:bg-zinc-600 dark:border-zinc-500",
    zinc: "text-white bg-zinc-600 border-zinc-700/90 hover:bg-zinc-700 shadow-sm"
  }

  @doc """
  Renders a Catalyst-style button.

  ## Examples

      <.catalyst_button>Click me</.catalyst_button>
      <.catalyst_button color={:dark}>Primary</.catalyst_button>
      <.catalyst_button variant={:outline}>Secondary</.catalyst_button>
      <.catalyst_button variant={:plain}>Tertiary</.catalyst_button>

  ## Attributes

  - `variant` - Button style: :solid (default), :outline, :plain
  - `color` - Button color: :dark (default), :zinc
  - `class` - Additional CSS classes
  """
  attr :variant, :atom, default: :solid, values: [:solid, :outline, :plain]
  attr :color, :atom, default: :dark, values: [:dark, :zinc]
  attr :class, :string, default: nil
  attr :rest, :global, include: ~w(href navigate patch method disabled form name value type phx-click phx-disable-with)

  slot :inner_block, required: true

  def catalyst_button(assigns) do
    variant_classes = case assigns.variant do
      :solid -> @button_solid_colors[assigns.color]
      :outline -> "border-zinc-950/10 text-zinc-950 hover:bg-zinc-950/5 dark:border-white/15 dark:text-white dark:hover:bg-white/5"
      :plain -> "border-transparent text-zinc-950 hover:bg-zinc-950/5 dark:text-white dark:hover:bg-white/10"
    end

    assigns =
      assigns
      |> assign(:button_base, @button_base)
      |> assign(:variant_classes, variant_classes)

    ~H"""
    <button
      class={[@button_base, @variant_classes, @class]}
      {@rest}
    >
      {render_slot(@inner_block)}
    </button>
    """
  end

  # ============================================
  # Typography Components
  # ============================================

  @doc """
  Renders a page heading.

  ## Examples

      <.heading>Dashboard</.heading>
      <.heading level={2}>Section Title</.heading>
      <.heading level={:h2}>Also Works</.heading>
  """
  attr :level, :any, default: 1
  attr :class, :string, default: nil
  attr :rest, :global

  slot :inner_block, required: true

  def heading(assigns) do
    level = normalize_level(assigns.level)
    assigns = assign(assigns, :tag, "h#{level}")

    ~H"""
    <.dynamic_tag
      tag_name={@tag}
      class={[
        "text-2xl font-semibold text-zinc-950 sm:text-xl dark:text-white",
        @class
      ]}
      {@rest}
    >
      {render_slot(@inner_block)}
    </.dynamic_tag>
    """
  end

  defp normalize_level(level) when is_integer(level), do: level
  defp normalize_level(:h1), do: 1
  defp normalize_level(:h2), do: 2
  defp normalize_level(:h3), do: 3
  defp normalize_level(:h4), do: 4
  defp normalize_level(:h5), do: 5
  defp normalize_level(:h6), do: 6
  defp normalize_level(_), do: 1

  @doc """
  Renders a section subheading.

  ## Examples

      <.subheading>Recent Activity</.subheading>
      <.subheading level={:h3}>Section</.subheading>
  """
  attr :level, :any, default: 2
  attr :class, :string, default: nil
  attr :rest, :global

  slot :inner_block, required: true

  def subheading(assigns) do
    level = normalize_level(assigns.level)
    assigns = assign(assigns, :tag, "h#{level}")

    ~H"""
    <.dynamic_tag
      tag_name={@tag}
      class={[
        "text-base font-semibold text-zinc-950 sm:text-sm dark:text-white",
        @class
      ]}
      {@rest}
    >
      {render_slot(@inner_block)}
    </.dynamic_tag>
    """
  end

  @doc """
  Renders body text with Catalyst styling.

  ## Examples

      <.text>Some description text</.text>
      <.text muted>Secondary information</.text>
  """
  attr :muted, :boolean, default: false
  attr :class, :string, default: nil
  attr :rest, :global

  slot :inner_block, required: true

  def text(assigns) do
    ~H"""
    <p
      class={[
        "text-sm",
        if(@muted, do: "text-zinc-500 dark:text-zinc-400", else: "text-zinc-700 dark:text-zinc-300"),
        @class
      ]}
      {@rest}
    >
      {render_slot(@inner_block)}
    </p>
    """
  end

  # ============================================
  # Stat Card Component
  # ============================================

  @doc """
  Renders a stat card for dashboard metrics.

  ## Examples

      <.stat_card title="Total Revenue" value="$45,231" />
      <.stat_card title="Active Users" value={2451}>
        <:detail>Last 30 days</:detail>
      </.stat_card>

  ## Attributes

  - `title` - Stat label
  - `value` - Primary value to display (can be string or number)
  """
  attr :title, :string, required: true
  attr :value, :any, required: true
  attr :class, :string, default: nil
  attr :rest, :global

  slot :detail, doc: "Optional detail text below value"

  def stat_card(assigns) do
    ~H"""
    <div
      class={[
        "bg-white shadow-sm rounded ring-1 ring-zinc-950/5 p-4 dark:bg-zinc-900 dark:ring-white/10",
        @class
      ]}
      {@rest}
    >
      <dt class="text-sm font-medium text-zinc-500 dark:text-zinc-400">{@title}</dt>
      <dd class="mt-2 flex items-baseline gap-x-2">
        <span class="text-3xl font-semibold tracking-tight text-zinc-950 dark:text-white">
          {@value}
        </span>
      </dd>
      <div :if={@detail != []} class="mt-2 text-xs text-zinc-500 dark:text-zinc-400">
        {render_slot(@detail)}
      </div>
    </div>
    """
  end

  # ============================================
  # Data Table Component
  # ============================================

  @doc """
  Renders a professional data table.

  ## Pattern 1: Simple slots (header/body)

      <.data_table>
        <:header>
          <th>Name</th>
          <th>Status</th>
        </:header>
        <:body>
          <%= for item <- @items do %>
            <tr><td>{item.name}</td><td>{item.status}</td></tr>
          <% end %>
        </:body>
      </.data_table>

  ## Pattern 2: Declarative with rows (col slots)

      <.data_table rows={@trades}>
        <:col :let={trade} label="Time">{trade.timestamp}</:col>
        <:col :let={trade} label="Amount">{trade.amount}</:col>
        <:action :let={trade}>
          <.link navigate={~p"/trades/\#{trade.id}"}>View</.link>
        </:action>
      </.data_table>
  """
  attr :id, :string, default: nil
  attr :rows, :list, default: nil
  attr :striped, :boolean, default: false
  attr :dense, :boolean, default: false
  attr :class, :string, default: nil
  attr :row_click, :any, default: nil, doc: "JS command or function for row click"
  attr :row_id, :any, default: nil, doc: "Function to generate row ID"
  attr :rest, :global

  slot :header, doc: "Simple header slot containing <th> elements"
  slot :body, doc: "Simple body slot containing <tr> elements"

  slot :col do
    attr :label, :string, required: true
    attr :class, :string
    attr :align, :atom, values: [:left, :center, :right]
  end

  slot :action, doc: "Slot for action buttons"

  def data_table(assigns) do
    assigns =
      assigns
      |> assign_new(:row_id, fn -> fn row -> "row-#{:erlang.phash2(row)}" end end)

    # Use simple pattern if header/body slots are provided, otherwise use declarative pattern
    if assigns.header != [] and assigns.body != [] do
      data_table_simple(assigns)
    else
      data_table_declarative(assigns)
    end
  end

  defp data_table_simple(assigns) do
    ~H"""
    <div class="flow-root">
      <div class={["-mx-4 -my-2 overflow-x-auto sm:-mx-6 lg:-mx-8", @class]}>
        <div class="inline-block min-w-full py-2 align-middle sm:px-6 lg:px-8">
          <table class="min-w-full text-left text-sm text-zinc-950 dark:text-white" {@rest}>
            <thead class="bg-zinc-50 dark:bg-zinc-800/50">
              <tr>
                {render_slot(@header)}
              </tr>
            </thead>
            <tbody class="divide-y divide-zinc-950/5 dark:divide-white/5">
              {render_slot(@body)}
            </tbody>
          </table>
        </div>
      </div>
    </div>
    """
  end

  defp data_table_declarative(assigns) do
    ~H"""
    <div class="flow-root">
      <div class={["-mx-4 -my-2 overflow-x-auto sm:-mx-6 lg:-mx-8", @class]}>
        <div class="inline-block min-w-full py-2 align-middle sm:px-6 lg:px-8">
          <table class="min-w-full text-left text-sm text-zinc-950 dark:text-white" {@rest}>
            <thead class="border-b border-zinc-950/10 text-sm text-zinc-500 dark:border-white/5 dark:text-zinc-400">
              <tr>
                <th
                  :for={col <- @col}
                  class={[
                    "px-4 py-3 font-medium first:pl-0 last:pr-0",
                    col[:align] == :right && "text-right",
                    col[:align] == :center && "text-center"
                  ]}
                >
                  {col[:label]}
                </th>
                <th :if={@action != []} class="px-4 py-3 font-medium text-right">
                  <span class="sr-only">Actions</span>
                </th>
              </tr>
            </thead>
            <tbody>
              <tr
                :for={row <- @rows || []}
                id={@row_id.(row)}
                class={[
                  @striped && "even:bg-zinc-950/2.5 dark:even:bg-white/2.5",
                  @row_click && "hover:bg-zinc-950/2.5 dark:hover:bg-white/2.5 cursor-pointer"
                ]}
                phx-click={@row_click && @row_click.(row)}
              >
                <td
                  :for={col <- @col}
                  class={[
                    "relative px-4 first:pl-0 last:pr-0",
                    !@striped && "border-b border-zinc-950/5 dark:border-white/5",
                    if(@dense, do: "py-2.5", else: "py-4"),
                    col[:class],
                    col[:align] == :right && "text-right",
                    col[:align] == :center && "text-center"
                  ]}
                >
                  {render_slot(col, row)}
                </td>
                <td
                  :if={@action != []}
                  class={[
                    "relative px-4 last:pr-0 text-right",
                    !@striped && "border-b border-zinc-950/5 dark:border-white/5",
                    if(@dense, do: "py-2.5", else: "py-4")
                  ]}
                >
                  <div class="flex items-center justify-end gap-x-2">
                    {render_slot(@action, row)}
                  </div>
                </td>
              </tr>
            </tbody>
          </table>
        </div>
      </div>
    </div>
    """
  end

  # ============================================
  # Description List Component
  # ============================================

  @doc """
  Renders a description list for key-value data.

  ## Examples

      <.description_list>
        <:item title="Wallet">{@wallet.address}</:item>
        <:item title="Total Trades">{@wallet.total_trades}</:item>
        <:item title="Win Rate">{format_percent(@wallet.win_rate)}</:item>
      </.description_list>
  """
  attr :class, :string, default: nil
  attr :rest, :global

  slot :item, required: true do
    attr :title, :string, required: true
  end

  def description_list(assigns) do
    ~H"""
    <dl class={["divide-y divide-zinc-950/10 dark:divide-white/10", @class]} {@rest}>
      <div :for={item <- @item} class="flex justify-between gap-x-4 py-3">
        <dt class="text-sm font-medium text-zinc-500 dark:text-zinc-400">{item[:title]}</dt>
        <dd class="text-sm text-zinc-950 dark:text-white">
          {render_slot(item)}
        </dd>
      </div>
    </dl>
    """
  end

  # ============================================
  # Divider Component
  # ============================================

  @doc """
  Renders a horizontal divider.

  ## Examples

      <.divider />
      <.divider soft />
  """
  attr :soft, :boolean, default: false, doc: "Use softer, less prominent divider"
  attr :class, :string, default: nil
  attr :rest, :global

  def divider(assigns) do
    ~H"""
    <hr
      class={[
        "w-full border-t",
        if(@soft, do: "border-zinc-950/5 dark:border-white/5", else: "border-zinc-950/10 dark:border-white/10"),
        @class
      ]}
      {@rest}
    />
    """
  end

  # ============================================
  # Alert Banner Component
  # ============================================

  @alert_colors %{
    info: "bg-zinc-50 text-zinc-700 ring-zinc-200 dark:bg-zinc-800/50 dark:text-zinc-300 dark:ring-zinc-700",
    success: "bg-zinc-50 text-zinc-700 ring-zinc-200 dark:bg-zinc-800/50 dark:text-zinc-300 dark:ring-zinc-700",
    warning: "bg-amber-50 text-amber-800 ring-amber-200 dark:bg-amber-900/20 dark:text-amber-200 dark:ring-amber-800",
    error: "bg-red-50 text-red-800 ring-red-200 dark:bg-red-900/20 dark:text-red-200 dark:ring-red-800"
  }

  @doc """
  Renders an alert banner.

  ## Examples

      <.alert_banner type={:info}>This is an informational message.</.alert_banner>
      <.alert_banner type={:error}>
        <:title>Error</:title>
        Something went wrong.
      </.alert_banner>
  """
  attr :type, :atom, default: :info, values: [:info, :success, :warning, :error]
  attr :class, :string, default: nil
  attr :rest, :global

  slot :title, doc: "Optional title for the alert"
  slot :inner_block, required: true

  def alert_banner(assigns) do
    alert_class = @alert_colors[assigns.type]
    assigns = assign(assigns, :alert_class, alert_class)

    ~H"""
    <div
      class={[
        "rounded p-4 ring-1 ring-inset",
        @alert_class,
        @class
      ]}
      role="alert"
      {@rest}
    >
      <div class="flex">
        <div class="flex-shrink-0">
          <.alert_icon kind={@type} />
        </div>
        <div class="ml-3">
          <p :if={@title != []} class="text-sm font-medium">{render_slot(@title)}</p>
          <div class={["text-sm", @title != [] && "mt-1"]}>
            {render_slot(@inner_block)}
          </div>
        </div>
      </div>
    </div>
    """
  end

  defp alert_icon(%{kind: :info} = assigns) do
    ~H"""
    <svg class="h-5 w-5" viewBox="0 0 20 20" fill="currentColor">
      <path fill-rule="evenodd" d="M18 10a8 8 0 11-16 0 8 8 0 0116 0zm-7-4a1 1 0 11-2 0 1 1 0 012 0zM9 9a.75.75 0 000 1.5h.253a.25.25 0 01.244.304l-.459 2.066A1.75 1.75 0 0010.747 15H11a.75.75 0 000-1.5h-.253a.25.25 0 01-.244-.304l.459-2.066A1.75 1.75 0 009.253 9H9z" clip-rule="evenodd" />
    </svg>
    """
  end

  defp alert_icon(%{kind: :success} = assigns) do
    ~H"""
    <svg class="h-5 w-5" viewBox="0 0 20 20" fill="currentColor">
      <path fill-rule="evenodd" d="M10 18a8 8 0 100-16 8 8 0 000 16zm3.857-9.809a.75.75 0 00-1.214-.882l-3.483 4.79-1.88-1.88a.75.75 0 10-1.06 1.061l2.5 2.5a.75.75 0 001.137-.089l4-5.5z" clip-rule="evenodd" />
    </svg>
    """
  end

  defp alert_icon(%{kind: :warning} = assigns) do
    ~H"""
    <svg class="h-5 w-5" viewBox="0 0 20 20" fill="currentColor">
      <path fill-rule="evenodd" d="M8.485 2.495c.673-1.167 2.357-1.167 3.03 0l6.28 10.875c.673 1.167-.17 2.625-1.516 2.625H3.72c-1.347 0-2.189-1.458-1.515-2.625L8.485 2.495zM10 5a.75.75 0 01.75.75v3.5a.75.75 0 01-1.5 0v-3.5A.75.75 0 0110 5zm0 9a1 1 0 100-2 1 1 0 000 2z" clip-rule="evenodd" />
    </svg>
    """
  end

  defp alert_icon(%{kind: :error} = assigns) do
    ~H"""
    <svg class="h-5 w-5" viewBox="0 0 20 20" fill="currentColor">
      <path fill-rule="evenodd" d="M10 18a8 8 0 100-16 8 8 0 000 16zM8.28 7.22a.75.75 0 00-1.06 1.06L8.94 10l-1.72 1.72a.75.75 0 101.06 1.06L10 11.06l1.72 1.72a.75.75 0 101.06-1.06L11.06 10l1.72-1.72a.75.75 0 00-1.06-1.06L10 8.94 8.28 7.22z" clip-rule="evenodd" />
    </svg>
    """
  end

  # ============================================
  # Tab Navigation Component
  # ============================================

  @doc """
  Renders tab navigation with Catalyst styling.

  ## Examples

      <.tabs>
        <:tab id="overview" active={@active_tab == :overview} phx-click="switch_tab" phx-value-tab="overview">
          Overview
        </:tab>
        <:tab id="alerts" active={@active_tab == :alerts} phx-click="switch_tab" phx-value-tab="alerts">
          Alerts
          <.badge :if={@alert_count > 0} color={:red} class="ml-2">{@alert_count}</.badge>
        </:tab>
      </.tabs>
  """
  attr :class, :string, default: nil
  attr :rest, :global

  slot :tab, required: true do
    attr :id, :string, required: true
    attr :active, :boolean
    attr :"phx-click", :string
    attr :"phx-value-tab", :string
  end

  def tabs(assigns) do
    ~H"""
    <div class={["border-b border-zinc-950/10 dark:border-white/10", @class]} {@rest}>
      <nav class="-mb-px flex space-x-8">
        <button
          :for={tab <- @tab}
          id={tab[:id]}
          class={[
            "whitespace-nowrap border-b-2 py-4 px-1 text-sm font-medium",
            if(tab[:active],
              do: "border-zinc-950 text-zinc-950 dark:border-white dark:text-white",
              else: "border-transparent text-zinc-500 hover:border-zinc-300 hover:text-zinc-700 dark:text-zinc-400 dark:hover:text-zinc-300"
            )
          ]}
          {assigns_to_attributes(tab, [:id, :active, :inner_block])}
        >
          {render_slot(tab)}
        </button>
      </nav>
    </div>
    """
  end

  # ============================================
  # Empty State Component
  # ============================================

  @doc """
  Renders an empty state placeholder.

  ## Examples

      <.empty_state title="No alerts" description="You're all caught up!" />
      <.empty_state>No data available yet.</.empty_state>
  """
  attr :title, :string, default: nil
  attr :description, :string, default: nil
  attr :class, :string, default: nil
  attr :rest, :global

  slot :inner_block, doc: "Content to display (alternative to title/description)"
  slot :action, doc: "Optional action button"

  def empty_state(assigns) do
    ~H"""
    <div class={["text-center py-12", @class]} {@rest}>
      <svg
        class="mx-auto h-12 w-12 text-zinc-400 dark:text-zinc-600"
        fill="none"
        viewBox="0 0 24 24"
        stroke="currentColor"
        aria-hidden="true"
      >
        <path
          stroke-linecap="round"
          stroke-linejoin="round"
          stroke-width="1.5"
          d="M2.25 13.5h3.86a2.25 2.25 0 012.012 1.244l.256.512a2.25 2.25 0 002.013 1.244h3.218a2.25 2.25 0 002.013-1.244l.256-.512a2.25 2.25 0 012.013-1.244h3.859m-19.5.338V18a2.25 2.25 0 002.25 2.25h15A2.25 2.25 0 0021.75 18v-4.162c0-.224-.034-.447-.1-.661L19.24 5.338a2.25 2.25 0 00-2.15-1.588H6.911a2.25 2.25 0 00-2.15 1.588L2.35 13.177a2.25 2.25 0 00-.1.661z"
        />
      </svg>
      <%= if @title do %>
        <h3 class="mt-2 text-sm font-semibold text-zinc-950 dark:text-white">{@title}</h3>
        <p :if={@description} class="mt-1 text-sm text-zinc-500 dark:text-zinc-400">
          {@description}
        </p>
      <% else %>
        <p class="mt-2 text-sm text-zinc-500 dark:text-zinc-400">
          {render_slot(@inner_block)}
        </p>
      <% end %>
      <div :if={@action != []} class="mt-6">
        {render_slot(@action)}
      </div>
    </div>
    """
  end

  # ============================================
  # Status Indicator Component
  # ============================================

  @doc """
  Renders a status indicator (dot with optional label).

  ## Examples

      <.status_indicator active={true} />
      <.status_indicator active={false} label="Monitor Inactive" />
  """
  attr :active, :boolean, required: true
  attr :label, :string, default: nil
  attr :class, :string, default: nil
  attr :rest, :global

  def status_indicator(assigns) do
    {dot_color, bg_color, text_color} = if assigns.active do
      {"bg-lime-500", "bg-lime-500/10", "text-lime-700 dark:text-lime-400"}
    else
      {"bg-zinc-400", "bg-zinc-500/10", "text-zinc-600 dark:text-zinc-400"}
    end

    assigns =
      assigns
      |> assign(:dot_color, dot_color)
      |> assign(:bg_color, bg_color)
      |> assign(:text_color, text_color)

    ~H"""
    <div
      class={[
        "inline-flex items-center gap-x-2 rounded-full px-3 py-1 text-sm font-medium",
        @bg_color,
        @text_color,
        @class
      ]}
      {@rest}
    >
      <span class={["h-2 w-2 rounded-full", @dot_color, @active && "animate-pulse"]}></span>
      <span :if={@label}>{@label}</span>
    </div>
    """
  end

  # ============================================
  # Action Link Component
  # ============================================

  @doc """
  Renders a text link styled for actions (table rows, etc).

  ## Examples

      <.action_link navigate={~p"/items/\#{item.id}"}>View</.action_link>
      <.action_link phx-click="delete" phx-value-id={item.id}>Delete</.action_link>
  """
  attr :class, :string, default: nil
  attr :rest, :global, include: ~w(href navigate patch method phx-click phx-value-id)

  slot :inner_block, required: true

  def action_link(assigns) do
    ~H"""
    <.link
      class={[
        "text-sm font-medium text-zinc-700 hover:text-zinc-950 dark:text-zinc-300 dark:hover:text-white",
        @class
      ]}
      {@rest}
    >
      {render_slot(@inner_block)}
    </.link>
    """
  end
end
