defmodule VolfefeMachine.Intelligence.MultiModelClient do
  @moduledoc """
  Client for multi-model sentiment classification using Python script.

  Runs multiple sentiment analysis models (DistilBERT, Twitter-RoBERTa, FinBERT)
  on the same text and returns all results for consensus calculation.

  Philosophy: Run ALL models, capture ALL data, calculate consensus in Elixir.
  """

  require Logger

  # Get paths that work in both dev and releases
  # :code.priv_dir works in releases where File.cwd! fails
  defp python_cmd do
    # Allow config override for custom python path (e.g., in production)
    Application.get_env(:volfefe_machine, :python_path, "venv/bin/python3")
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
    # Pass text directly via stdin (no temp file needed, avoids quoting issues)
    # Use timeout: :infinity since model loading can take >5s on first run
    try do
      case System.cmd(python_cmd(), [script_path()],
                      input: text,
                      timeout: :infinity,
                      stderr_to_stdout: false) do
        {output, 0} ->
          {:ok, output}

        {error_output, exit_code} ->
          Logger.error("Multi-model classification failed (exit #{exit_code}): #{error_output}")
          {:error, {:python_error, exit_code, error_output}}
      end
    rescue
      e ->
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

        {:ok, %{
          results: parsed_results,
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
