defmodule VolfefeMachine.Polymarket.ReferenceCaseMatcher do
  @moduledoc """
  ML-powered matching of reference cases to Polymarket markets.

  Uses FinBERT + NER to automatically link news events (reference cases)
  to relevant prediction markets based on:
  1. Named entity extraction (people, organizations, locations)
  2. Keyword overlap scoring
  3. Semantic similarity (via entity context matching)

  ## Usage

      # Find matching markets for a reference case
      {:ok, matches} = ReferenceCaseMatcher.find_matching_markets(reference_case)

      # Auto-link all unlinked reference cases
      {:ok, stats} = ReferenceCaseMatcher.auto_link_reference_cases()

  ## Algorithm

  1. Extract entities from reference case name/description using BERT-NER
  2. Query markets containing those entities
  3. Score each market by:
     - Entity overlap (40% weight)
     - Keyword match (30% weight)
     - Category match (20% weight)
     - Date proximity (10% weight)
  4. Return ranked matches with confidence scores
  """

  require Logger
  import Ecto.Query
  alias VolfefeMachine.Repo
  alias VolfefeMachine.Polymarket.{InsiderReferenceCase, Market}
  alias VolfefeMachine.Intelligence.MultiModelClient

  @doc """
  Find matching markets for a reference case using NER and keyword matching.

  ## Parameters

  - `reference_case` - InsiderReferenceCase struct
  - `opts` - Options:
    - `:limit` - Max markets to return (default: 10)
    - `:min_score` - Minimum match score (default: 0.3)
    - `:category_filter` - Restrict to category (default: nil)

  ## Returns

  - `{:ok, [%{market: market, score: float, breakdown: map}]}`
  - `{:error, reason}`
  """
  def find_matching_markets(%InsiderReferenceCase{} = ref_case, opts \\ []) do
    limit = Keyword.get(opts, :limit, 10)
    min_score = Keyword.get(opts, :min_score, 0.3)
    category_filter = Keyword.get(opts, :category_filter, nil)

    # Build search text from case details
    search_text = build_search_text(ref_case)

    Logger.info("[ReferenceCaseMatcher] Processing: #{ref_case.case_name}")

    # Extract entities using NER
    case extract_entities(search_text) do
      {:ok, entities} ->
        Logger.debug("[ReferenceCaseMatcher] Extracted #{length(entities)} entities: #{inspect(entities)}")

        # Find candidate markets
        candidates = find_candidate_markets(entities, ref_case, category_filter)
        Logger.debug("[ReferenceCaseMatcher] Found #{length(candidates)} candidate markets")

        # Score each candidate
        scored = candidates
        |> Enum.map(fn market ->
          {score, breakdown} = calculate_match_score(ref_case, market, entities)
          %{market: market, score: score, breakdown: breakdown}
        end)
        |> Enum.filter(&(&1.score >= min_score))
        |> Enum.sort_by(&(&1.score), :desc)
        |> Enum.take(limit)

        Logger.info("[ReferenceCaseMatcher] Found #{length(scored)} matches above threshold")

        {:ok, scored}

      {:error, reason} ->
        Logger.warning("[ReferenceCaseMatcher] Entity extraction failed: #{inspect(reason)}")
        # Fallback to keyword-only matching
        {:ok, find_markets_by_keywords(ref_case, limit, min_score, category_filter)}
    end
  end

  @doc """
  Auto-link all unlinked Polymarket reference cases.

  ## Parameters

  - `opts` - Options:
    - `:auto_apply` - Automatically apply top match if score > 0.7 (default: false)
    - `:dry_run` - Don't save changes (default: true)

  ## Returns

  - `{:ok, %{processed: n, linked: m, candidates: list}}`
  """
  def auto_link_reference_cases(opts \\ []) do
    auto_apply = Keyword.get(opts, :auto_apply, false)
    dry_run = Keyword.get(opts, :dry_run, true)

    # Find Polymarket cases without condition_id
    unlinked = from(r in InsiderReferenceCase,
      where: r.platform == "polymarket" and is_nil(r.condition_id)
    ) |> Repo.all()

    Logger.info("[ReferenceCaseMatcher] Processing #{length(unlinked)} unlinked cases")

    results = Enum.map(unlinked, fn ref_case ->
      case find_matching_markets(ref_case, limit: 5) do
        {:ok, [top | _rest] = matches} when length(matches) > 0 ->
          result = %{
            case_name: ref_case.case_name,
            matches: Enum.map(matches, fn m ->
              %{
                question: m.market.question,
                condition_id: m.market.condition_id,
                score: Float.round(m.score, 3),
                breakdown: m.breakdown
              }
            end)
          }

          # Auto-apply if score is high enough
          if auto_apply and not dry_run and top.score > 0.7 do
            apply_match(ref_case, top.market)
            Map.put(result, :auto_linked, true)
          else
            result
          end

        {:ok, []} ->
          %{case_name: ref_case.case_name, matches: [], no_match: true}

        {:error, reason} ->
          %{case_name: ref_case.case_name, error: reason}
      end
    end)

    linked_count = Enum.count(results, &Map.get(&1, :auto_linked, false))

    {:ok, %{
      processed: length(unlinked),
      linked: linked_count,
      candidates: results
    }}
  end

  @doc """
  Apply a market match to a reference case (link them).
  """
  def apply_match(%InsiderReferenceCase{} = ref_case, %Market{} = market) do
    ref_case
    |> InsiderReferenceCase.changeset(%{
      condition_id: market.condition_id,
      market_slug: market.slug,
      market_question: market.question
    })
    |> Repo.update()
  end

  # ============================================
  # Private Functions
  # ============================================

  defp build_search_text(%InsiderReferenceCase{} = ref_case) do
    [ref_case.case_name, ref_case.description, ref_case.market_question]
    |> Enum.reject(&is_nil/1)
    |> Enum.join(" ")
  end

  defp extract_entities(text) do
    case MultiModelClient.classify(text) do
      {:ok, %{entities: %{extracted: entities}}} when is_list(entities) ->
        # Group by entity type and extract unique values
        grouped = entities
        |> Enum.group_by(& &1["label"])
        |> Enum.flat_map(fn {label, items} ->
          items
          |> Enum.map(& &1["word"])
          |> Enum.uniq()
          |> Enum.map(&%{text: &1, type: label})
        end)

        {:ok, grouped}

      {:ok, _} ->
        # No entities extracted, return empty
        {:ok, []}

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp find_candidate_markets(entities, ref_case, category_filter) do
    # Build search terms from entities and keywords
    entity_texts = Enum.map(entities, & &1.text) |> Enum.map(&String.downcase/1)
    keywords = extract_keywords(ref_case)

    search_terms = (entity_texts ++ keywords) |> Enum.uniq() |> Enum.take(10)

    if length(search_terms) == 0 do
      []
    else
      # Build query with ILIKE for each search term
      base_query = from(m in Market,
        where: not is_nil(m.question),
        limit: 100
      )

      # Add category filter if specified (use existing atoms only to prevent atom exhaustion)
      base_query = if category_filter do
        category_atom = safe_to_category_atom(category_filter)
        if category_atom do
          from(m in base_query, where: m.category == ^category_atom)
        else
          base_query
        end
      else
        # Or match reference case category
        if ref_case.category do
          category_atom = safe_to_category_atom(ref_case.category)
          if category_atom do
            from(m in base_query, where: m.category == ^category_atom)
          else
            base_query
          end
        else
          base_query
        end
      end

      # Search for markets containing any of the search terms
      # Escape regex special chars and build proper POSIX regex pattern for ~*
      search_pattern = search_terms
      |> Enum.map(&Regex.escape/1)
      |> Enum.join("|")

      # Use dynamic query with POSIX regex (case-insensitive)
      query = from(m in base_query,
        where: fragment("? ~* ?", m.question, ^search_pattern)
      )

      Repo.all(query)
    end
  end

  defp find_markets_by_keywords(ref_case, limit, min_score, category_filter) do
    keywords = extract_keywords(ref_case)

    if length(keywords) == 0 do
      []
    else
      candidates = find_candidate_markets([], ref_case, category_filter)

      candidates
      |> Enum.map(fn market ->
        {score, breakdown} = calculate_keyword_score(ref_case, market, keywords)
        %{market: market, score: score, breakdown: breakdown}
      end)
      |> Enum.filter(&(&1.score >= min_score))
      |> Enum.sort_by(&(&1.score), :desc)
      |> Enum.take(limit)
    end
  end

  defp extract_keywords(%InsiderReferenceCase{} = ref_case) do
    text = build_search_text(ref_case)

    # Extract meaningful keywords (skip common words)
    stopwords = ~w(the a an is are was were will be been have has had do does did can could would should may might must shall to of and or for in on at by from with as it this that these those)

    text
    |> String.downcase()
    |> String.replace(~r/[^\w\s]/, " ")
    |> String.split(~r/\s+/)
    |> Enum.reject(&(String.length(&1) < 3))
    |> Enum.reject(&(&1 in stopwords))
    |> Enum.uniq()
    |> Enum.take(15)
  end

  defp calculate_match_score(ref_case, market, entities) do
    question_lower = String.downcase(market.question || "")

    # Entity overlap score (40%)
    entity_texts = Enum.map(entities, & &1.text) |> Enum.map(&String.downcase/1)
    entity_matches = Enum.count(entity_texts, &String.contains?(question_lower, &1))
    entity_score = if length(entity_texts) > 0, do: entity_matches / length(entity_texts), else: 0

    # Keyword overlap score (30%)
    keywords = extract_keywords(ref_case)
    keyword_matches = Enum.count(keywords, &String.contains?(question_lower, &1))
    keyword_score = if length(keywords) > 0, do: keyword_matches / length(keywords), else: 0

    # Category match score (20%)
    category_score = if ref_case.category do
      ref_cat = String.to_atom(ref_case.category)
      if market.category == ref_cat, do: 1.0, else: 0.0
    else
      0.5  # Neutral if no category specified
    end

    # Date proximity score (10%)
    date_score = calculate_date_proximity(ref_case.event_date, market.resolution_date)

    # Weighted total
    total = (entity_score * 0.4) + (keyword_score * 0.3) + (category_score * 0.2) + (date_score * 0.1)

    breakdown = %{
      entity_score: Float.round(entity_score, 3),
      entity_matches: entity_matches,
      entity_total: length(entity_texts),
      keyword_score: Float.round(keyword_score, 3),
      keyword_matches: keyword_matches,
      keyword_total: length(keywords),
      category_score: Float.round(category_score, 3),
      date_score: Float.round(date_score, 3)
    }

    {Float.round(total, 4), breakdown}
  end

  defp calculate_keyword_score(ref_case, market, keywords) do
    question_lower = String.downcase(market.question || "")

    keyword_matches = Enum.count(keywords, &String.contains?(question_lower, &1))
    keyword_score = if length(keywords) > 0, do: keyword_matches / length(keywords), else: 0

    category_score = if ref_case.category do
      ref_cat = String.to_atom(ref_case.category)
      if market.category == ref_cat, do: 1.0, else: 0.0
    else
      0.5
    end

    date_score = calculate_date_proximity(ref_case.event_date, market.resolution_date)

    total = (keyword_score * 0.6) + (category_score * 0.25) + (date_score * 0.15)

    breakdown = %{
      keyword_score: Float.round(keyword_score, 3),
      keyword_matches: keyword_matches,
      keyword_total: length(keywords),
      category_score: Float.round(category_score, 3),
      date_score: Float.round(date_score, 3)
    }

    {Float.round(total, 4), breakdown}
  end

  defp calculate_date_proximity(nil, _), do: 0.5
  defp calculate_date_proximity(_, nil), do: 0.5
  defp calculate_date_proximity(event_date, resolution_date) do
    # Convert to Date if DateTime
    event_date = case event_date do
      %DateTime{} = dt -> DateTime.to_date(dt)
      %Date{} = d -> d
      _ -> nil
    end

    resolution_date = case resolution_date do
      %DateTime{} = dt -> DateTime.to_date(dt)
      %Date{} = d -> d
      _ -> nil
    end

    if event_date && resolution_date do
      days_diff = abs(Date.diff(event_date, resolution_date))
      # Score decays with distance, 1.0 for same day, 0.5 at 30 days, 0.1 at 90+ days
      cond do
        days_diff <= 1 -> 1.0
        days_diff <= 7 -> 0.9
        days_diff <= 14 -> 0.8
        days_diff <= 30 -> 0.6
        days_diff <= 60 -> 0.4
        days_diff <= 90 -> 0.2
        true -> 0.1
      end
    else
      0.5
    end
  end

  # Safely convert category to atom without exhausting atom table
  # Only accepts atoms that exist in Market.category Ecto.Enum
  @valid_categories ~w(politics corporate legal crypto sports entertainment science other)a

  defp safe_to_category_atom(value) when is_atom(value) do
    if value in @valid_categories, do: value, else: nil
  end

  defp safe_to_category_atom(value) when is_binary(value) do
    try do
      atom = String.to_existing_atom(value)
      if atom in @valid_categories, do: atom, else: nil
    rescue
      ArgumentError -> nil
    end
  end

  defp safe_to_category_atom(_), do: nil
end
