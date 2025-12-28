#!/usr/bin/env python3
"""
Train a classifier head on top of CLIP embeddings.
Uses frozen CLIP vision encoder + simple sklearn classifier.
"""

import json
import sys
from pathlib import Path

import numpy as np
from PIL import Image
from pdf2image import convert_from_path
from sklearn.linear_model import LogisticRegression
from sklearn.ensemble import RandomForestClassifier
from sklearn.model_selection import cross_validate, LeaveOneOut
import joblib
import torch
from transformers import CLIPProcessor, CLIPModel


def load_training_samples(runs_dir: Path) -> list[dict]:
    """Load all training samples from runs directory."""
    samples = []
    for sample_file in runs_dir.rglob("*-sample.json"):
        with open(sample_file) as f:
            sample = json.load(f)
            img_path = Path(sample["image"]["path"])
            if img_path.exists():
                samples.append(sample)
            else:
                print(f"  Skipping {sample['id']}: image not found")
    return samples


def pdf_to_image(pdf_path: Path) -> Image.Image:
    """Convert first page of PDF to PIL Image."""
    pages = convert_from_path(pdf_path, first_page=1, last_page=1)
    return pages[0]


def get_clip_embeddings(
    samples: list[dict],
    model: CLIPModel,
    processor: CLIPProcessor,
    device: str
) -> np.ndarray:
    """Get CLIP embeddings for all sample images."""
    embeddings = []

    # Set model to inference mode
    model.training = False

    for i, sample in enumerate(samples):
        img_path = Path(sample["image"]["path"])
        print(f"  [{i+1}/{len(samples)}] Processing {img_path.name}...", end="")

        # Load image (handle PDF)
        if img_path.suffix.lower() == ".pdf":
            image = pdf_to_image(img_path)
        else:
            image = Image.open(img_path)

        # Get CLIP embedding
        inputs = processor(images=image, return_tensors="pt").to(device)
        with torch.no_grad():
            features = model.get_image_features(**inputs)

        # Normalize and convert to numpy
        features = features / features.norm(dim=-1, keepdim=True)
        embeddings.append(features.cpu().numpy().flatten())
        print(" done")

    return np.array(embeddings)


def main():
    runs_dir = Path(__file__).parent.parent / "runs"
    output_dir = Path(__file__).parent / "models"
    output_dir.mkdir(exist_ok=True)

    print("=" * 60)
    print("CLIP Classifier Training")
    print("=" * 60)

    # Load samples
    print("\n1. Loading training samples...")
    samples = load_training_samples(runs_dir)
    print(f"   Found {len(samples)} samples with images")

    if len(samples) < 5:
        print("   ERROR: Need at least 5 samples to train")
        sys.exit(1)

    # Extract labels
    labels = np.array([s["labels"]["isCorrectProduct"] for s in samples])
    print(f"   Label distribution: {sum(labels)} correct, {len(labels) - sum(labels)} incorrect")

    # Check for class imbalance
    if sum(labels) == len(labels) or sum(labels) == 0:
        print("   ERROR: Need examples of both classes (correct and incorrect)")
        sys.exit(1)

    # Load CLIP
    print("\n2. Loading CLIP model...")
    device = "mps" if torch.backends.mps.is_available() else "cpu"
    print(f"   Using device: {device}")

    model = CLIPModel.from_pretrained("openai/clip-vit-base-patch32")
    processor = CLIPProcessor.from_pretrained("openai/clip-vit-base-patch32")
    model.to(device)
    print("   Model loaded")

    # Get embeddings
    print("\n3. Computing embeddings...")
    embeddings = get_clip_embeddings(samples, model, processor, device)
    print(f"   Embedding shape: {embeddings.shape}")

    # Save embeddings for reuse
    np.save(output_dir / "embeddings.npy", embeddings)
    np.save(output_dir / "labels.npy", labels)
    with open(output_dir / "sample_ids.json", "w") as f:
        json.dump([s["id"] for s in samples], f, indent=2)
    print("   Saved embeddings to models/")

    # Train classifier
    print("\n4. Training classifier...")

    # Try multiple classifiers
    classifiers = {
        "LogisticRegression": LogisticRegression(class_weight="balanced", max_iter=1000),
        "RandomForest": RandomForestClassifier(n_estimators=100, class_weight="balanced"),
    }

    best_clf = None
    best_score = 0
    best_name = ""

    for name, clf in classifiers.items():
        # Use Leave-One-Out CV for small datasets
        if len(samples) < 20:
            cv = LeaveOneOut()
        else:
            cv = 5

        cv_results = cross_validate(clf, embeddings, labels, cv=cv, scoring="accuracy")
        scores = cv_results["test_score"]
        mean_score = scores.mean()
        print(f"   {name}: {mean_score:.1%} accuracy (std: {scores.std():.1%})")

        if mean_score > best_score:
            best_score = mean_score
            best_clf = clf
            best_name = name

    # Train final model on all data
    print(f"\n5. Training final model ({best_name})...")
    best_clf.fit(embeddings, labels)

    # Save model using joblib (sklearn standard)
    model_path = output_dir / "classifier.joblib"
    joblib.dump(best_clf, model_path)
    print(f"   Saved to {model_path}")

    # Show what the model learned (for interpretability)
    if hasattr(best_clf, "feature_importances_"):
        top_features = np.argsort(best_clf.feature_importances_)[-10:]
        print(f"   Top feature indices: {top_features}")

    # Summary
    print("\n" + "=" * 60)
    print("TRAINING COMPLETE")
    print("=" * 60)
    print(f"Samples: {len(samples)}")
    print(f"Best model: {best_name}")
    print(f"CV Accuracy: {best_score:.1%}")
    print(f"Model saved: {model_path}")


if __name__ == "__main__":
    main()
