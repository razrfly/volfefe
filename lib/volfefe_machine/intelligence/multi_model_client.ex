defmodule VolfefeMachine.Intelligence.MultiModelClient do
  @moduledoc """
  Client for multi-model sentiment classification + NER using Python script.

  Runs multiple sentiment analysis models (DistilBERT, Twitter-RoBERTa, FinBERT)
  AND named entity recognition (BERT-base-NER) on the same text.

  Philosophy: Run ALL models, capture ALL data, calculate consensus in Elixir.
  """

  require Logger

  # Get paths that work in both dev and releases
  # :code.priv_dir works in releases where File.cwd! fails
  defp python_cmd do
    # Allow config override for custom python path (e.g., in production)
    default_path = Path.join(File.cwd!(), "venv/bin/python3")
    Application.get_env(:volfefe_machine, :python_path, default_path)
  end

  defp script_path do
    priv_dir = :code.priv_dir(:volfefe_machine) |> to_string()
    Path.join(priv_dir, "ml/classify_multi_model.py")
  end

  @doc """
  Classify text using all configured sentiment models.

  ## Examples

      iex> MultiModelClient.classify("Great news for America!")
      {:ok, %{
        results: [
          %{model_id: "distilbert", sentiment: "positive", confidence: 0.9999, ...},
          %{model_id: "twitter_roberta", sentiment: "positive", confidence: 0.9892, ...},
          %{model_id: "finbert", sentiment: "positive", confidence: 1.0, ...}
        ],
        text_info: %{...},
        total_latency_ms: 1566,
        models_used: ["distilbert", "twitter_roberta", "finbert"],
        successful_models: 3
      }}

  ## Returns

    - `{:ok, results}` - All model results with metadata
    - `{:error, reason}` - Classification failed

  """
  def classify(text) when is_binary(text) do
    case run_classification(text) do
      {:ok, json_output} -> parse_results(json_output)
      {:error, reason} -> {:error, reason}
    end
  end

  defp run_classification(text) do
    # Write text to temp file and pass via stdin redirect
    # System.cmd doesn't support :input/:stdin options in Elixir 1.18
    temp_file = Path.join(System.tmp_dir!(), "volfefe_input_#{:rand.uniform(999999)}.txt")

    try do
      File.write!(temp_file, text)

      # Use shell to pipe file to python script
      cmd = "cat #{temp_file} | #{python_cmd()} #{script_path()}"

      case System.cmd("sh", ["-c", cmd], stderr_to_stdout: false) do
        {output, 0} ->
          File.rm(temp_file)
          {:ok, output}

        {error_output, exit_code} ->
          File.rm(temp_file)
          Logger.error("Multi-model classification failed (exit #{exit_code}): #{error_output}")
          {:error, {:python_error, exit_code, error_output}}
      end
    rescue
      e ->
        if File.exists?(temp_file), do: File.rm(temp_file)
        Logger.error("Failed to run multi-model classification: #{inspect(e)}")
        {:error, {:system_error, e}}
    end
  end

  defp parse_results(json_string) do
    case Jason.decode(json_string) do
      {:ok, %{"error" => error, "message" => message}} ->
        {:error, {:classification_error, error, message}}

      {:ok, %{"results" => results} = data} ->
        parsed_results = Enum.map(results, &parse_model_result/1)
        parsed_entities = parse_entities(data["entities"])

        {:ok, %{
          results: parsed_results,
          entities: parsed_entities,
          text_info: data["text_info"],
          system_info: data["system_info"],
          total_latency_ms: data["total_latency_ms"],
          models_used: data["models_used"],
          total_models: data["total_models"],
          successful_models: data["successful_models"],
          failed_models: data["failed_models"]
        }}

      {:ok, unexpected} ->
        Logger.error("Unexpected JSON format: #{inspect(unexpected)}")
        {:error, {:parse_error, :unexpected_format}}

      {:error, reason} ->
        Logger.error("Failed to parse JSON: #{inspect(reason)}")
        {:error, {:json_parse_error, reason}}
    end
  end

  defp parse_model_result(%{"error" => error} = result) do
    # Model failed, return error info
    %{
      model_id: result["model_id"],
      model_version: result["model_version"],
      error: error,
      meta: result["meta"] || %{}
    }
  end

  defp parse_model_result(result) do
    # Successful classification
    %{
      model_id: result["model_id"],
      model_version: result["model_version"],
      sentiment: result["sentiment"],
      confidence: result["confidence"],
      meta: result["meta"]
    }
  end

  defp parse_entities(nil), do: nil

  defp parse_entities(%{"error" => error} = entities_data) do
    # Entity extraction failed
    %{
      model_id: entities_data["model_id"],
      model_version: entities_data["model_version"],
      error: error,
      extracted: [],
      stats: entities_data["stats"] || %{},
      meta: entities_data["meta"] || %{}
    }
  end

  defp parse_entities(entities_data) do
    # Successful entity extraction
    extracted_entities = Enum.map(entities_data["extracted"] || [], fn entity ->
      %{
        text: entity["text"],
        type: entity["type"],
        confidence: entity["confidence"],
        start: entity["start"],
        end: entity["end"],
        context: entity["context"]
      }
    end)

    %{
      model_id: entities_data["model_id"],
      model_version: entities_data["model_version"],
      extracted: extracted_entities,
      stats: entities_data["stats"] || %{},
      meta: entities_data["meta"] || %{}
    }
  end

  @doc """
  Get list of configured models from config.

  Returns model configurations from Application config.
  """
  def configured_models do
    config = Application.get_env(:volfefe_machine, :sentiment_models, [])
    Keyword.get(config, :models, [])
  end

  @doc """
  Get model weight for consensus calculation.

  Returns the weight for a specific model from config, defaults to 1.0.
  """
  def model_weight(model_id) do
    configured_models()
    |> Enum.find(%{weight: 1.0}, fn m -> m.id == model_id end)
    |> Map.get(:weight, 1.0)
  end
end
