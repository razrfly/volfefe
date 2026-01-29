#!/usr/bin/env python3
"""
Isolation Forest Anomaly Detector for Insider Trading Detection.

Uses scikit-learn's IsolationForest algorithm which is ideal for:
- High-dimensional data
- Extreme class imbalance (few positives in many negatives)
- Unsupervised anomaly detection

Input: JSON array of feature vectors
Output: JSON with anomaly scores and predictions
"""

import sys
import json
import os
import numpy as np
from pathlib import Path
from typing import List, Dict, Any, Optional
import warnings

# Suppress sklearn warnings for cleaner output
warnings.filterwarnings('ignore')

try:
    from sklearn.ensemble import IsolationForest
    from sklearn.preprocessing import StandardScaler
    import joblib
except ImportError as e:
    print(json.dumps({
        "error": "missing_dependency",
        "message": f"Required library not installed: {e}. Install with: pip install scikit-learn joblib"
    }))
    sys.exit(1)


class AnomalyDetector:
    """Isolation Forest-based anomaly detector for trade features."""

    def __init__(self, contamination: float = 0.01, n_estimators: int = 100):
        """
        Initialize the detector.

        Args:
            contamination: Expected proportion of outliers (0.01 = 1%)
            n_estimators: Number of trees in the forest
        """
        self.contamination = contamination
        self.n_estimators = n_estimators
        self.model: Optional[IsolationForest] = None
        self.scaler: Optional[StandardScaler] = None
        self.feature_names: List[str] = []
        self.is_fitted = False

    def fit(self, features: np.ndarray, feature_names: List[str] = None):
        """
        Fit the model on training data.

        Args:
            features: 2D array of shape (n_samples, n_features)
            feature_names: Optional list of feature names
        """
        self.feature_names = feature_names or [f"feature_{i}" for i in range(features.shape[1])]

        # Scale features
        self.scaler = StandardScaler()
        scaled_features = self.scaler.fit_transform(features)

        # Train Isolation Forest
        self.model = IsolationForest(
            n_estimators=self.n_estimators,
            contamination=self.contamination,
            random_state=42,
            n_jobs=-1,  # Use all CPUs
            warm_start=False
        )
        self.model.fit(scaled_features)
        self.is_fitted = True

        return self

    def predict(self, features: np.ndarray) -> Dict[str, Any]:
        """
        Predict anomaly scores for new data.

        Args:
            features: 2D array of shape (n_samples, n_features)

        Returns:
            Dict with predictions, scores, and confidence
        """
        if not self.is_fitted:
            raise ValueError("Model not fitted. Call fit() first or load a model.")

        # Scale features
        scaled_features = self.scaler.transform(features)

        # Get predictions (-1 = anomaly, 1 = normal)
        predictions = self.model.predict(scaled_features)

        # Get anomaly scores (lower = more anomalous)
        # decision_function returns values where lower is more anomalous
        raw_scores = self.model.decision_function(scaled_features)

        # Convert to anomaly probability (0 = normal, 1 = very anomalous)
        # Use sigmoid-like transformation on inverted scores
        # Multiplier of 1.0 (was 2.0) spreads scores across wider range
        anomaly_scores = 1 / (1 + np.exp(raw_scores * 1.0))

        # Calculate confidence based on score distance from threshold
        threshold = self.model.offset_  # Internal threshold
        distances = np.abs(raw_scores - threshold)
        confidence = np.minimum(distances / 2, 1.0)  # Cap at 1.0

        return {
            "predictions": predictions.tolist(),  # -1 = anomaly, 1 = normal
            "anomaly_scores": anomaly_scores.tolist(),  # 0-1, higher = more anomalous
            "confidence": confidence.tolist(),  # 0-1, higher = more confident
            "raw_scores": raw_scores.tolist(),  # Original decision function values
            "threshold": float(threshold)
        }

    def fit_predict(self, features: np.ndarray, feature_names: List[str] = None) -> Dict[str, Any]:
        """Fit model and return predictions on same data."""
        self.fit(features, feature_names)
        return self.predict(features)

    def save(self, path: str):
        """Save model to disk."""
        if not self.is_fitted:
            raise ValueError("Cannot save unfitted model")

        joblib.dump({
            'model': self.model,
            'scaler': self.scaler,
            'feature_names': self.feature_names,
            'contamination': self.contamination,
            'n_estimators': self.n_estimators
        }, path)

    # Trusted directory for model files (relative to priv/ml)
    TRUSTED_MODEL_DIR = Path(__file__).parent / "models"

    @staticmethod
    def _is_path_within(child: Path, parent: Path) -> bool:
        """
        Check if child path is within parent directory.
        Uses is_relative_to() (Python 3.9+) with fallback for older versions.
        """
        child = child.resolve()
        parent = parent.resolve()
        try:
            # Python 3.9+ method - safe against prefix attacks
            return child.is_relative_to(parent)
        except AttributeError:
            # Fallback for Python < 3.9: use os.path.commonpath
            try:
                return os.path.commonpath([str(child), str(parent)]) == str(parent)
            except ValueError:
                # Different drives on Windows or other path issues
                return False

    @classmethod
    def load(cls, path: str) -> 'AnomalyDetector':
        """Load model from disk with path validation."""
        # Resolve to absolute path
        resolved_path = Path(path).resolve()

        # Ensure trusted model directory exists for validation
        trusted_dir = cls.TRUSTED_MODEL_DIR.resolve()

        # Validate path is within trusted directory or is an allowed filename pattern
        # Allow paths within priv/ml/models/ or paths ending in .joblib within priv/
        priv_dir = Path(__file__).parent.parent.resolve()

        is_trusted = (
            # Within explicit models directory (using proper containment check)
            cls._is_path_within(resolved_path, trusted_dir) or
            # Or within priv directory with .joblib extension
            (cls._is_path_within(resolved_path, priv_dir) and resolved_path.suffix == '.joblib')
        )

        if not is_trusted:
            raise ValueError(
                f"Untrusted model path: {path}. "
                f"Models must be within {trusted_dir} or {priv_dir}/*.joblib"
            )

        if not resolved_path.exists():
            raise FileNotFoundError(f"Model file not found: {path}")

        data = joblib.load(str(resolved_path))
        detector = cls(
            contamination=data['contamination'],
            n_estimators=data['n_estimators']
        )
        detector.model = data['model']
        detector.scaler = data['scaler']
        detector.feature_names = data['feature_names']
        detector.is_fitted = True
        return detector


def process_input(input_data: Dict[str, Any]) -> Dict[str, Any]:
    """
    Process input and return predictions.

    Input format:
    {
        "action": "fit_predict" | "predict" | "fit" | "save" | "load",
        "features": [[f1, f2, ...], ...],  # 2D array
        "feature_names": ["size_zscore", "timing_zscore", ...],  # Optional
        "contamination": 0.01,  # Optional, default 0.01
        "n_estimators": 100,  # Optional, default 100
        "model_path": "path/to/model.joblib"  # For save/load
    }
    """
    action = input_data.get("action", "fit_predict")
    features = np.array(input_data.get("features", []))
    feature_names = input_data.get("feature_names", [])
    contamination = input_data.get("contamination", 0.01)
    n_estimators = input_data.get("n_estimators", 100)
    model_path = input_data.get("model_path")

    if action == "load" and model_path:
        detector = AnomalyDetector.load(model_path)
        return {"status": "loaded", "feature_names": detector.feature_names}

    if len(features) == 0:
        return {"error": "no_features", "message": "No feature data provided"}

    if features.ndim == 1:
        features = features.reshape(1, -1)

    # Coerce features to numeric dtype to handle None/mixed types
    # Replace None with np.nan, then convert to float
    def to_numeric(val):
        if val is None:
            return np.nan
        try:
            return float(val)
        except (TypeError, ValueError):
            return np.nan

    # Apply numeric conversion element-wise if array has object dtype
    if features.dtype == object:
        features = np.vectorize(to_numeric)(features).astype(np.float64)
    else:
        features = features.astype(np.float64)

    # Handle NaN/inf values
    features = np.nan_to_num(features, nan=0.0, posinf=0.0, neginf=0.0)

    detector = AnomalyDetector(contamination=contamination, n_estimators=n_estimators)

    if action == "fit_predict":
        result = detector.fit_predict(features, feature_names)
        result["status"] = "success"
        result["n_samples"] = len(features)
        result["n_features"] = features.shape[1]
        return result

    elif action == "fit":
        detector.fit(features, feature_names)
        if model_path:
            detector.save(model_path)
        return {
            "status": "fitted",
            "n_samples": len(features),
            "n_features": features.shape[1],
            "saved_to": model_path
        }

    elif action == "predict":
        if model_path:
            detector = AnomalyDetector.load(model_path)
        else:
            return {"error": "no_model", "message": "Provide model_path for predict action"}

        result = detector.predict(features)
        result["status"] = "success"
        result["n_samples"] = len(features)
        return result

    elif action == "save" and model_path:
        detector.fit(features, feature_names)
        detector.save(model_path)
        return {"status": "saved", "path": model_path}

    else:
        return {"error": "invalid_action", "message": f"Unknown action: {action}"}


def main():
    """Main entry point - reads JSON from stdin, writes JSON to stdout."""
    try:
        # Read all input
        input_text = sys.stdin.read()

        if not input_text.strip():
            print(json.dumps({"error": "empty_input", "message": "No input provided"}))
            return

        input_data = json.loads(input_text)
        result = process_input(input_data)
        print(json.dumps(result))

    except json.JSONDecodeError as e:
        print(json.dumps({
            "error": "invalid_json",
            "message": str(e)
        }))
    except Exception as e:
        print(json.dumps({
            "error": "processing_error",
            "message": str(e),
            "type": type(e).__name__
        }))


if __name__ == "__main__":
    main()
