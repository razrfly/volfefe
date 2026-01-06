defmodule VolfefeMachine.MarketData.Priority do
  @moduledoc """
  Market data capture prioritization logic.

  Implements 3-tier priority system to optimize API credit usage:
  - Tier 1 (🥇): Market hours + asset targeting + strong sentiment
  - Tier 2 (🥈): Market hours + strong sentiment + entity mentions
  - Tier 3 (🥉): Has asset targets (even outside hours)
  - Skip (❌): Low-value content

  See: GitHub Issue #90
  """

  alias VolfefeMachine.MarketData.Snapshot

  @doc """
  Evaluates content priority for market data capture.

  Returns `{:eligible, tier}` or `{:skip, reason}`.

  ## Examples

      iex> evaluate(%Content{...})
      {:eligible, 1}

      iex> evaluate(%Content{...})
      {:skip, "low_confidence"}
  """
  def evaluate(content) do
    cond do
      # Tier 1: Market hours + asset targeting + strong sentiment
      is_market_hours?(content.published_at) and
      has_content_targets?(content) and
      strong_sentiment?(content.classification) ->
        {:eligible, 1}

      # Tier 2: Market hours + strong sentiment + entities
      is_market_hours?(content.published_at) and
      strong_sentiment?(content.classification) and
      multiple_entities?(content.classification) ->
        {:eligible, 2}

      # Tier 3: Has asset targets (even outside hours)
      has_content_targets?(content) and
      not_weekend?(content.published_at) ->
        {:eligible, 3}

      # Skip: Weekend posts
      is_weekend?(content.published_at) ->
        {:skip, "weekend_post"}

      # Skip: Neutral sentiment with low confidence
      neutral_low_confidence?(content.classification) ->
        {:skip, "low_confidence"}

      # Skip: No market relevance signals
      true ->
        {:skip, "no_market_signals"}
    end
  end

  @doc """
  Returns priority tier label.

  ## Examples

      iex> tier_label(1)
      "🥇 Tier 1: Highest"
  """
  def tier_label(1), do: "🥇 Tier 1: Highest"
  def tier_label(2), do: "🥈 Tier 2: Medium"
  def tier_label(3), do: "🥉 Tier 3: Lower"
  def tier_label(_), do: "❌ Skip"

  @doc """
  Returns priority tier description.
  """
  def tier_description(1), do: "Market hours + asset targets + strong sentiment"
  def tier_description(2), do: "Market hours + strong sentiment + entities"
  def tier_description(3), do: "Has asset targets (outside hours OK)"
  def tier_description(_), do: "Low priority or no market signals"

  @doc """
  Returns CSS class for tier badge.
  """
  def tier_badge_class(1), do: "bg-green-100 text-green-800 border-green-300"
  def tier_badge_class(2), do: "bg-blue-100 text-blue-800 border-blue-300"
  def tier_badge_class(3), do: "bg-yellow-100 text-yellow-800 border-yellow-300"
  def tier_badge_class(_), do: "bg-gray-100 text-gray-600 border-gray-300"

  # Private helper functions

  defp is_market_hours?(datetime) when is_nil(datetime), do: false

  defp is_market_hours?(datetime) do
    # Use existing market state logic from Snapshot module
    market_state = Snapshot.determine_market_state(datetime)
    market_state == "regular_hours"
  end

  defp has_content_targets?(%{content_targets: targets}) when is_list(targets) do
    length(targets) > 0
  end
  defp has_content_targets?(_), do: false

  defp strong_sentiment?(%{sentiment: sentiment, confidence: confidence})
       when sentiment in ["positive", "negative"] and confidence >= 0.80 do
    true
  end
  defp strong_sentiment?(_), do: false

  defp multiple_entities?(%{meta: meta}) when is_map(meta) do
    total = get_in(meta, ["entities", "stats", "total_entities"])
    is_integer(total) and total >= 2
  end
  defp multiple_entities?(_), do: false

  defp neutral_low_confidence?(%{sentiment: "neutral", confidence: confidence})
       when confidence < 0.70 do
    true
  end
  defp neutral_low_confidence?(_), do: false

  defp not_weekend?(datetime) when is_nil(datetime), do: false
  defp not_weekend?(datetime), do: Date.day_of_week(datetime) not in [6, 7]

  defp is_weekend?(datetime) when is_nil(datetime), do: false
  defp is_weekend?(datetime), do: Date.day_of_week(datetime) in [6, 7]
end
