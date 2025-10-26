defmodule VolfefeMachine.Intelligence.FinbertClient do
  @moduledoc """
  Client for calling FinBERT classification via Python script.

  This module uses Elixir Ports to call the Python FinBERT classifier,
  passing text via stdin and receiving JSON classification results via stdout.

  ## Architecture

  - Python script: priv/ml/classify.py
  - Model: yiyanghkust/finbert-tone (FinBERT)
  - Communication: Port with stdin/stdout JSON protocol
  - Error handling: Returns {:error, reason} tuples for failures

  ## Requirements

  - Python 3.9+ with transformers library installed
  - FinBERT model downloaded (happens automatically on first run)
  - ~2-3GB RAM for model inference
  """

  require Logger

  @script_path "priv/ml/classify.py"
  @python_cmd "venv/bin/python3"

  @doc """
  Classifies text using FinBERT model.

  Returns a map with sentiment, confidence, model_version, and metadata.

  ## Examples

      iex> classify("Stock market hitting record highs!")
      {:ok, %{
        sentiment: "positive",
        confidence: 0.95,
        model_version: "finbert-tone-v1.0",
        meta: %{
          "raw_scores" => %{
            "positive" => 0.95,
            "negative" => 0.02,
            "neutral" => 0.03
          }
        }
      }}

      iex> classify("")
      {:error, :no_text_provided}

      iex> classify(nil)
      {:error, :no_text_provided}
  """
  def classify(text) when is_binary(text) and text != "" do
    script_path = Path.join(File.cwd!(), @script_path)

    # Verify script exists
    if not File.exists?(script_path) do
      Logger.error("FinBERT script not found at #{script_path}")
      {:error, :script_not_found}
    else
      # Call Python script via Port
      case call_python_script(script_path, text) do
        {:ok, result} -> parse_result(result)
        {:error, reason} -> {:error, reason}
      end
    end
  end

  def classify(nil), do: {:error, :no_text_provided}
  def classify(""), do: {:error, :no_text_provided}

  @doc """
  Batch classifies multiple texts.

  Returns a list of results, maintaining order.
  Each result is either {:ok, classification} or {:error, reason}.

  ## Examples

      iex> batch_classify(["Good news!", "Bad news", "Neutral statement"])
      [
        {:ok, %{sentiment: "positive", ...}},
        {:ok, %{sentiment: "negative", ...}},
        {:ok, %{sentiment: "neutral", ...}}
      ]
  """
  def batch_classify(texts) when is_list(texts) do
    Enum.map(texts, &classify/1)
  end

  # Private helper functions

  defp call_python_script(script_path, text) do
    try do
      # Use venv Python if available, otherwise system python3
      python_path =
        case File.exists?(Path.join(File.cwd!(), "venv/bin/python3")) do
          true -> Path.join(File.cwd!(), "venv/bin/python3")
          false -> System.find_executable("python3")
        end

      # Create temp file for input
      temp_file = Path.join(System.tmp_dir!(), "finbert_input_#{System.unique_integer([:positive])}.txt")
      File.write!(temp_file, text)

      try do
        # Run Python script with input from temp file
        {output, exit_code} = System.cmd("sh", ["-c", "cat #{temp_file} | #{python_path} #{script_path}"], stderr_to_stdout: true)

        case exit_code do
          0 -> {:ok, output}
          _ ->
            Logger.error("Python script exited with code #{exit_code}: #{output}")
            {:error, :classification_failed}
        end
      after
        # Clean up temp file
        File.rm(temp_file)
      end
    rescue
      error ->
        Logger.error("Failed to call Python script: #{inspect(error)}")
        {:error, :python_execution_failed}
    end
  end

  defp parse_result(output) do
    # Output may contain multiple lines (JSON + device messages)
    # Find the first line that looks like JSON
    json_line =
      output
      |> String.split("\n")
      |> Enum.find(fn line -> String.starts_with?(String.trim(line), "{") end)

    case json_line do
      nil ->
        Logger.error("No JSON found in output: #{output}")
        {:error, :invalid_response}

      line ->
        case Jason.decode(line) do
          {:ok, %{"error" => error_type, "message" => message}} ->
            Logger.error("FinBERT error: #{error_type} - #{message}")
            {:error, String.to_atom(error_type)}

          {:ok, %{"sentiment" => sentiment, "confidence" => confidence} = result} ->
            {:ok, %{
              sentiment: sentiment,
              confidence: confidence,
              model_version: result["model_version"],
              meta: result["meta"]
            }}

          {:ok, unexpected} ->
            Logger.error("Unexpected response format: #{inspect(unexpected)}")
            {:error, :invalid_response}

          {:error, reason} ->
            Logger.error("Failed to parse JSON response: #{inspect(reason)}")
            {:error, :invalid_json}
        end
    end
  end
end
