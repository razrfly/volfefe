defmodule VolfefeMachine.Polymarket.InsiderPattern do
  @moduledoc """
  Ecto schema for insider trading patterns.

  Stores detection rule definitions with performance metrics:
  - Pattern conditions as flexible JSON rules
  - Precision/recall/F1 scores from validation
  - Alert thresholds and lift metrics

  ## Pattern Condition Format

  Conditions are stored as a map with the following structure:

      %{
        "rules" => [
          %{"metric" => "size_zscore", "operator" => ">=", "value" => 2.0},
          %{"metric" => "was_correct", "operator" => "==", "value" => true}
        ],
        "logic" => "AND",  # "AND" or "OR"
        "min_matches" => 2  # For "OR" logic, minimum rules that must match
      }

  ## Supported Operators

  - `>=`, `>`, `<=`, `<` - Numeric comparisons
  - `==`, `!=` - Equality checks
  - `between` - Range check (value should be [min, max])

  ## Metrics Available

  - `size_zscore` - Trade size z-score
  - `timing_zscore` - Timing z-score
  - `price_extremity_zscore` - Price extremity z-score
  - `anomaly_score` - Combined anomaly score
  - `was_correct` - Whether trade was correct
  - `profit_loss` - Profit/loss amount

  ## Usage

      # Create a pattern
      {:ok, pattern} = Polymarket.create_insider_pattern(%{
        pattern_name: "whale_correct",
        description: "Large correct trades",
        conditions: %{
          "rules" => [
            %{"metric" => "size_zscore", "operator" => ">=", "value" => 2.0},
            %{"metric" => "was_correct", "operator" => "==", "value" => true}
          ],
          "logic" => "AND"
        }
      })

      # Match a trade against patterns
      matches = Polymarket.match_patterns(trade_score)
  """

  use Ecto.Schema
  import Ecto.Changeset

  schema "polymarket_insider_patterns" do
    field :pattern_name, :string
    field :description, :string

    # Pattern conditions as JSON
    field :conditions, :map

    # Performance metrics
    field :true_positives, :integer, default: 0
    field :false_positives, :integer, default: 0
    field :precision, :decimal
    field :recall, :decimal
    field :f1_score, :decimal

    # Thresholds
    field :alert_threshold, :decimal
    field :lift, :decimal

    field :is_active, :boolean, default: true
    field :validated_at, :utc_datetime

    timestamps(type: :utc_datetime)
  end

  @required_fields ~w(pattern_name conditions)a
  @optional_fields ~w(
    description true_positives false_positives
    precision recall f1_score alert_threshold lift
    is_active validated_at
  )a

  def changeset(pattern, attrs) do
    pattern
    |> cast(attrs, @required_fields ++ @optional_fields)
    |> validate_required(@required_fields)
    |> validate_conditions()
    |> unique_constraint(:pattern_name)
  end

  defp validate_conditions(changeset) do
    case get_change(changeset, :conditions) do
      nil -> changeset
      conditions ->
        if valid_conditions?(conditions) do
          changeset
        else
          add_error(changeset, :conditions, "invalid condition format")
        end
    end
  end

  defp valid_conditions?(%{"rules" => rules}) when is_list(rules) do
    Enum.all?(rules, &valid_rule?/1)
  end
  defp valid_conditions?(_), do: false

  defp valid_rule?(%{"metric" => m, "operator" => o, "value" => _v})
       when is_binary(m) and is_binary(o), do: true
  defp valid_rule?(_), do: false

  @doc """
  Evaluates whether a trade matches this pattern's conditions.

  ## Parameters

  - `pattern` - InsiderPattern struct
  - `trade_data` - Map with trade metrics (from TradeScore + Trade)

  ## Returns

  - `{true, score}` - Pattern matches with confidence score
  - `{false, 0}` - Pattern doesn't match
  """
  def evaluate(%__MODULE__{conditions: conditions}, trade_data) do
    rules = Map.get(conditions, "rules", [])
    logic = Map.get(conditions, "logic", "AND")
    min_matches = Map.get(conditions, "min_matches", 1)

    results = Enum.map(rules, fn rule ->
      evaluate_rule(rule, trade_data)
    end)

    matched_count = Enum.count(results, & &1)
    total_rules = length(rules)

    case logic do
      "AND" ->
        if Enum.all?(results), do: {true, 1.0}, else: {false, 0}

      "OR" ->
        if matched_count >= min_matches do
          {true, matched_count / total_rules}
        else
          {false, 0}
        end

      _ ->
        {false, 0}
    end
  end

  defp evaluate_rule(%{"metric" => metric, "operator" => op, "value" => value}, data) do
    actual = get_metric_value(data, metric)

    case {actual, op} do
      {nil, _} -> false
      {actual, ">="} -> actual >= value
      {actual, ">"} -> actual > value
      {actual, "<="} -> actual <= value
      {actual, "<"} -> actual < value
      {actual, "=="} -> actual == value
      {actual, "!="} -> actual != value
      {actual, "between"} when is_list(value) ->
        [min, max] = value
        actual >= min and actual <= max
      _ -> false
    end
  end

  defp get_metric_value(data, metric) do
    # Try to get from map with string or atom key
    value = Map.get(data, metric) || Map.get(data, String.to_atom(metric))

    # Convert Decimal to float for comparison
    case value do
      %Decimal{} = d -> Decimal.to_float(d)
      v -> v
    end
  end

  @doc """
  Calculates precision from true/false positive counts.
  Precision = TP / (TP + FP)
  """
  def calculate_precision(%__MODULE__{true_positives: tp, false_positives: fp})
      when tp + fp > 0 do
    precision = tp / (tp + fp)
    Decimal.from_float(Float.round(precision, 4))
  end
  def calculate_precision(_), do: nil

  @doc """
  Calculates recall from true positives and total insiders.
  Recall = TP / Total Insiders
  """
  def calculate_recall(%__MODULE__{true_positives: tp}, total_insiders)
      when total_insiders > 0 do
    recall = tp / total_insiders
    Decimal.from_float(Float.round(recall, 4))
  end
  def calculate_recall(_, _), do: nil

  @doc """
  Calculates F1 score from precision and recall.
  F1 = 2 * (precision * recall) / (precision + recall)
  """
  def calculate_f1(%Decimal{} = precision, %Decimal{} = recall) do
    p = Decimal.to_float(precision)
    r = Decimal.to_float(recall)

    if p + r > 0 do
      f1 = 2 * (p * r) / (p + r)
      Decimal.from_float(Float.round(f1, 4))
    else
      nil
    end
  end
  def calculate_f1(_, _), do: nil

  @doc """
  Calculates lift - how much better than random the pattern is.
  Lift = (TP / (TP + FP)) / (Total Insiders / Total Trades)
  """
  def calculate_lift(%__MODULE__{true_positives: tp, false_positives: fp}, total_insiders, total_trades)
      when tp + fp > 0 and total_trades > 0 do
    precision = tp / (tp + fp)
    baseline = total_insiders / total_trades

    if baseline > 0 do
      lift = precision / baseline
      Decimal.from_float(Float.round(lift, 4))
    else
      nil
    end
  end
  def calculate_lift(_, _, _), do: nil
end
