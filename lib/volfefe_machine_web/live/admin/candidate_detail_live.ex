defmodule VolfefeMachineWeb.Admin.CandidateDetailLive do
  @moduledoc """
  LiveView for detailed investigation of a candidate.

  Provides:
  - Full trade context (market, size, timing, outcome)
  - Anomaly breakdown visualization
  - Pattern matches with scores
  - Wallet profile and history
  - Investigation workflow actions
  """

  use VolfefeMachineWeb, :live_view

  import LiveToast
  alias VolfefeMachine.Polymarket

  @impl true
  def mount(%{"id" => id}, _session, socket) do
    case Polymarket.get_investigation_candidate(String.to_integer(id)) do
      nil ->
        {:ok,
         socket
         |> put_flash(:error, "Candidate not found")
         |> push_navigate(to: ~p"/admin/polymarket?tab=candidates")}

      candidate ->
        wallet_data = load_wallet_data(candidate.wallet_address)
        similar_candidates = load_similar_candidates(candidate)

        {:ok,
         socket
         |> assign(:page_title, "Candidate ##{candidate.id}")
         |> assign(:candidate, candidate)
         |> assign(:wallet, wallet_data.wallet)
         |> assign(:wallet_trades, wallet_data.trades)
         |> assign(:similar_candidates, similar_candidates)
         |> assign(:resolution_form, %{"resolution" => "", "notes" => ""})
         |> assign(:show_resolve_modal, false)}
    end
  end

  @impl true
  def handle_event("start_investigation", _params, socket) do
    candidate = socket.assigns.candidate

    case Polymarket.start_investigation(candidate, "admin") do
      {:ok, updated} ->
        {:noreply,
         socket
         |> assign(:candidate, updated)
         |> put_toast(:success, "Investigation started")}

      {:error, _} ->
        {:noreply, put_toast(socket, :error, "Failed to start investigation")}
    end
  end

  @impl true
  def handle_event("show_resolve_modal", _params, socket) do
    {:noreply, assign(socket, :show_resolve_modal, true)}
  end

  @impl true
  def handle_event("hide_resolve_modal", _params, socket) do
    {:noreply, assign(socket, :show_resolve_modal, false)}
  end

  @impl true
  def handle_event("resolve_candidate", %{"resolution" => resolution, "notes" => notes}, socket) do
    candidate = socket.assigns.candidate

    case Polymarket.resolve_candidate(candidate, resolution, notes: notes, resolved_by: "admin") do
      {:ok, updated} ->
        {:noreply,
         socket
         |> assign(:candidate, updated)
         |> assign(:show_resolve_modal, false)
         |> put_toast(:success, "Candidate resolved as #{resolution}")}

      {:error, _} ->
        {:noreply, put_toast(socket, :error, "Failed to resolve candidate")}
    end
  end

  @impl true
  def handle_event("dismiss_candidate", _params, socket) do
    candidate = socket.assigns.candidate

    case Polymarket.dismiss_candidate(candidate, "Dismissed from detail view", "admin") do
      {:ok, updated} ->
        {:noreply,
         socket
         |> assign(:candidate, updated)
         |> put_toast(:success, "Candidate dismissed")}

      {:error, _} ->
        {:noreply, put_toast(socket, :error, "Failed to dismiss candidate")}
    end
  end

  @impl true
  def handle_event("add_note", %{"note" => note}, socket) do
    candidate = socket.assigns.candidate

    case Polymarket.add_investigation_note(candidate, note, "admin") do
      {:ok, updated} ->
        {:noreply,
         socket
         |> assign(:candidate, updated)
         |> put_toast(:success, "Note added")}

      {:error, _} ->
        {:noreply, put_toast(socket, :error, "Failed to add note")}
    end
  end

  # Private functions

  defp load_wallet_data(wallet_address) do
    case Polymarket.get_wallet(wallet_address) do
      {:ok, wallet} ->
        trades = Polymarket.get_wallet_trades(wallet_address, limit: 20)
        %{wallet: wallet, trades: trades}

      {:error, _} ->
        %{wallet: nil, trades: []}
    end
  end

  defp load_similar_candidates(candidate) do
    # Get other candidates from the same wallet or with similar patterns
    Polymarket.list_investigation_candidates(
      wallet_address: candidate.wallet_address,
      limit: 5
    )
    |> Enum.reject(&(&1.id == candidate.id))
  end

  # Helper functions for templates

  def priority_badge_class("critical"), do: "bg-red-100 text-red-800 ring-1 ring-red-600/20"
  def priority_badge_class("high"), do: "bg-orange-100 text-orange-800 ring-1 ring-orange-600/20"
  def priority_badge_class("medium"), do: "bg-yellow-100 text-yellow-800 ring-1 ring-yellow-600/20"
  def priority_badge_class("low"), do: "bg-green-100 text-green-800 ring-1 ring-green-600/20"
  def priority_badge_class(_), do: "bg-gray-100 text-gray-800 ring-1 ring-gray-600/20"

  def status_badge_class("undiscovered"), do: "bg-blue-100 text-blue-800"
  def status_badge_class("investigating"), do: "bg-yellow-100 text-yellow-800"
  def status_badge_class("resolved"), do: "bg-green-100 text-green-800"
  def status_badge_class("dismissed"), do: "bg-gray-100 text-gray-800"
  def status_badge_class(_), do: "bg-gray-100 text-gray-800"

  def severity_class("extreme"), do: "text-red-600 font-bold"
  def severity_class("very_high"), do: "text-orange-600 font-semibold"
  def severity_class("high"), do: "text-yellow-600"
  def severity_class("elevated"), do: "text-blue-600"
  def severity_class(_), do: "text-gray-600"

  def format_probability(nil), do: "N/A"
  def format_probability(%Decimal{} = d), do: "#{Decimal.round(Decimal.mult(d, 100), 1)}%"
  def format_probability(f) when is_float(f), do: "#{Float.round(f * 100, 1)}%"
  def format_probability(n), do: "#{n}%"

  def format_decimal(nil), do: "N/A"
  def format_decimal(%Decimal{} = d), do: Decimal.round(d, 2) |> Decimal.to_string()
  def format_decimal(n), do: "#{n}"

  def format_datetime(nil), do: "N/A"

  def format_datetime(%DateTime{} = dt) do
    Calendar.strftime(dt, "%Y-%m-%d %H:%M")
  end

  def format_datetime(%NaiveDateTime{} = dt) do
    Calendar.strftime(dt, "%Y-%m-%d %H:%M")
  end

  def format_wallet(nil), do: "Unknown"

  def format_wallet(address) when byte_size(address) > 10 do
    "#{String.slice(address, 0, 6)}...#{String.slice(address, -4, 4)}"
  end

  def format_wallet(address), do: address

  def format_hours(nil), do: "N/A"
  def format_hours(%Decimal{} = d) do
    hours = Decimal.to_float(d)
    cond do
      hours < 1 -> "#{round(hours * 60)}m"
      hours < 24 -> "#{Float.round(hours, 1)}h"
      true -> "#{Float.round(hours / 24, 1)}d"
    end
  end
  def format_hours(n), do: "#{n}h"

  def relative_time(nil), do: "N/A"

  def relative_time(%DateTime{} = dt) do
    seconds = DateTime.diff(DateTime.utc_now(), dt)
    format_relative_seconds(seconds)
  end

  def relative_time(%NaiveDateTime{} = dt) do
    {:ok, datetime} = DateTime.from_naive(dt, "Etc/UTC")
    relative_time(datetime)
  end

  defp format_relative_seconds(seconds) when seconds < 0, do: "just now"
  defp format_relative_seconds(seconds) when seconds < 60, do: "#{seconds}s ago"
  defp format_relative_seconds(seconds) when seconds < 3600, do: "#{div(seconds, 60)}m ago"
  defp format_relative_seconds(seconds) when seconds < 86400, do: "#{div(seconds, 3600)}h ago"
  defp format_relative_seconds(seconds), do: "#{div(seconds, 86400)}d ago"

  def severity_bar_color("extreme"), do: "bg-red-600"
  def severity_bar_color("very_high"), do: "bg-orange-500"
  def severity_bar_color("high"), do: "bg-yellow-500"
  def severity_bar_color("elevated"), do: "bg-blue-500"
  def severity_bar_color(_), do: "bg-gray-400"

  def pattern_match_badge(data) when is_map(data) do
    score = data["score"] || data["match"] || 0

    cond do
      is_number(score) and score >= 0.8 -> "bg-red-100 text-red-800"
      is_number(score) and score >= 0.5 -> "bg-yellow-100 text-yellow-800"
      true -> "bg-green-100 text-green-800"
    end
  end

  def pattern_match_badge(_), do: "bg-green-100 text-green-800"
end
