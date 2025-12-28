#!/usr/bin/env python3
"""
Predict page classification using trained CLIP classifier.
"""

import sys
from pathlib import Path

import numpy as np
from PIL import Image
from pdf2image import convert_from_path
import joblib
import torch
from transformers import CLIPProcessor, CLIPModel


class PageClassifier:
    """Classifies webpage screenshots using CLIP embeddings."""

    def __init__(self, model_dir: Path = None):
        if model_dir is None:
            model_dir = Path(__file__).parent / "models"

        self.model_dir = model_dir
        self.classifier = None
        self.clip_model = None
        self.processor = None
        self.device = None

    def load(self):
        """Load CLIP and classifier models."""
        print("Loading models...")

        # Load classifier
        classifier_path = self.model_dir / "classifier.joblib"
        if not classifier_path.exists():
            raise FileNotFoundError(f"No trained classifier at {classifier_path}")
        self.classifier = joblib.load(classifier_path)

        # Load CLIP
        self.device = "mps" if torch.backends.mps.is_available() else "cpu"
        self.clip_model = CLIPModel.from_pretrained("openai/clip-vit-base-patch32")
        self.processor = CLIPProcessor.from_pretrained("openai/clip-vit-base-patch32")
        self.clip_model.to(self.device)
        self.clip_model.training = False

        print(f"Models loaded (device: {self.device})")

    def get_embedding(self, image_path: Path) -> np.ndarray:
        """Get CLIP embedding for an image."""
        # Load image
        if image_path.suffix.lower() == ".pdf":
            pages = convert_from_path(image_path, first_page=1, last_page=1)
            image = pages[0]
        else:
            image = Image.open(image_path)

        # Get embedding
        inputs = self.processor(images=image, return_tensors="pt").to(self.device)
        with torch.no_grad():
            features = self.clip_model.get_image_features(**inputs)

        features = features / features.norm(dim=-1, keepdim=True)
        return features.cpu().numpy().flatten()

    def predict(self, image_path: Path) -> dict:
        """Predict if page shows correct product."""
        if self.classifier is None:
            self.load()

        embedding = self.get_embedding(Path(image_path))
        embedding = embedding.reshape(1, -1)

        prediction = self.classifier.predict(embedding)[0]
        probabilities = self.classifier.predict_proba(embedding)[0]

        return {
            "is_correct_product": bool(prediction),
            "confidence": float(max(probabilities)),
            "probabilities": {
                "incorrect": float(probabilities[0]),
                "correct": float(probabilities[1])
            }
        }


def main():
    if len(sys.argv) < 2:
        print("Usage: python predict.py <image_path>")
        sys.exit(1)

    image_path = Path(sys.argv[1])
    if not image_path.exists():
        print(f"Error: File not found: {image_path}")
        sys.exit(1)

    classifier = PageClassifier()
    result = classifier.predict(image_path)

    print(f"\nPrediction for: {image_path.name}")
    print(f"  Correct product: {result['is_correct_product']}")
    print(f"  Confidence: {result['confidence']:.1%}")
    print(f"  P(incorrect): {result['probabilities']['incorrect']:.1%}")
    print(f"  P(correct): {result['probabilities']['correct']:.1%}")


if __name__ == "__main__":
    main()
