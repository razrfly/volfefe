defmodule VolfefeMachine.Intelligence.ModelRegistry do
  @moduledoc """
  Central registry for ML models used in sentiment analysis and entity extraction.

  Provides a unified interface to query available models, their types, and configurations.
  Models are defined in config/ml_models.exs.

  ## Usage

      # List all models
      ModelRegistry.list_models()

      # Get specific model
      ModelRegistry.get_model("finbert")

      # List models by type
      ModelRegistry.models_by_type(:sentiment)
      ModelRegistry.models_by_type(:ner)
  """

  @type model_type :: :sentiment | :ner | :all
  @type model_id :: String.t() | atom()

  @type model :: %{
          id: String.t(),
          name: String.t(),
          type: String.t(),
          enabled: boolean(),
          weight: float() | nil,
          description: String.t() | nil
        }

  # NER models are hardcoded since they're not in config yet
  @ner_models [
    %{
      id: "bert_base_ner",
      name: "dslim/bert-base-NER",
      type: "ner",
      enabled: true,
      weight: nil,
      description: "BERT-base model for Named Entity Recognition (ORG, LOC, PER, MISC)"
    }
  ]

  @doc """
  Lists all configured ML models.

  ## Options

    * `:type` - Filter by model type (`:sentiment`, `:ner`, or `:all` [default])
    * `:enabled_only` - Only return enabled models (default: true)

  ## Examples

      iex> ModelRegistry.list_models()
      [%{id: "distilbert", ...}, %{id: "twitter_roberta", ...}, ...]

      iex> ModelRegistry.list_models(type: :sentiment)
      [%{id: "distilbert", ...}, %{id: "twitter_roberta", ...}, ...]

      iex> ModelRegistry.list_models(enabled_only: false)
      [%{id: "distilbert", enabled: true, ...}, %{id: "disabled_model", enabled: false, ...}]
  """
  @spec list_models(keyword()) :: [model()]
  def list_models(opts \\ []) do
    type = Keyword.get(opts, :type, :all)
    enabled_only = Keyword.get(opts, :enabled_only, true)

    models =
      case type do
        :sentiment -> get_sentiment_models()
        :ner -> @ner_models
        :all -> get_sentiment_models() ++ @ner_models
      end

    if enabled_only do
      Enum.filter(models, & &1.enabled)
    else
      models
    end
  end

  @doc """
  Gets a specific model by ID.

  ## Examples

      iex> ModelRegistry.get_model("finbert")
      %{id: "finbert", name: "yiyanghkust/finbert-tone", ...}

      iex> ModelRegistry.get_model("nonexistent")
      nil
  """
  @spec get_model(model_id()) :: model() | nil
  def get_model(id) when is_atom(id), do: get_model(to_string(id))

  def get_model(id) when is_binary(id) do
    list_models(enabled_only: false)
    |> Enum.find(&(&1.id == id))
  end

  @doc """
  Lists all models of a specific type.

  ## Examples

      iex> ModelRegistry.models_by_type(:sentiment)
      [%{id: "distilbert", ...}, %{id: "twitter_roberta", ...}, ...]

      iex> ModelRegistry.models_by_type(:ner)
      [%{id: "bert_base_ner", ...}]
  """
  @spec models_by_type(model_type()) :: [model()]
  def models_by_type(type) do
    list_models(type: type)
  end

  @doc """
  Gets all enabled sentiment models with their weights.

  Used for multi-model consensus calculation.

  ## Examples

      iex> ModelRegistry.sentiment_models_with_weights()
      [
        %{id: "distilbert", weight: 0.4, ...},
        %{id: "twitter_roberta", weight: 0.4, ...},
        %{id: "finbert", weight: 0.2, ...}
      ]
  """
  @spec sentiment_models_with_weights() :: [model()]
  def sentiment_models_with_weights do
    models_by_type(:sentiment)
    |> Enum.filter(&(&1.weight != nil))
  end

  @doc """
  Checks if a model exists and is enabled.

  ## Examples

      iex> ModelRegistry.model_enabled?("finbert")
      true

      iex> ModelRegistry.model_enabled?("nonexistent")
      false
  """
  @spec model_enabled?(model_id()) :: boolean()
  def model_enabled?(id) do
    case get_model(id) do
      nil -> false
      model -> model.enabled
    end
  end

  @doc """
  Gets all model types available in the registry.

  ## Examples

      iex> ModelRegistry.available_types()
      [:sentiment, :ner]
  """
  @spec available_types() :: [atom()]
  def available_types do
    [:sentiment, :ner]
  end

  # Private functions

  defp get_sentiment_models do
    config = Application.get_env(:volfefe_machine, :sentiment_models, [])
    models = Keyword.get(config, :models, [])

    Enum.map(models, fn model ->
      %{
        id: model.id,
        name: model.name,
        type: model.type,
        enabled: model.enabled,
        weight: model.weight,
        description: model.notes
      }
    end)
  end
end
