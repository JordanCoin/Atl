#!/usr/bin/env python3
"""
Use CLIP text-image similarity to verify correct product.
No training needed - just compare image to expected product description.
"""

import sys
from pathlib import Path

from PIL import Image
from pdf2image import convert_from_path
import torch
from transformers import CLIPProcessor, CLIPModel


class ProductVerifier:
    """Verify product pages match expected product using CLIP similarity."""

    def __init__(self):
        self.device = "mps" if torch.backends.mps.is_available() else "cpu"
        self.model = None
        self.processor = None

    def load(self):
        print(f"Loading CLIP (device: {self.device})...")
        self.model = CLIPModel.from_pretrained("openai/clip-vit-base-patch32")
        self.processor = CLIPProcessor.from_pretrained("openai/clip-vit-base-patch32")
        self.model.to(self.device)
        self.model.training = False
        print("Loaded.")

    def verify(self, image_path: Path, expected_product: str, negative_examples: list[str] = None) -> dict:
        """
        Check if image shows the expected product.

        Args:
            image_path: Path to screenshot
            expected_product: What should be on the page, e.g. "AirPods Pro wireless earbuds"
            negative_examples: Optional list of wrong products to compare against
        """
        if self.model is None:
            self.load()

        # Load image
        if image_path.suffix.lower() == ".pdf":
            pages = convert_from_path(image_path, first_page=1, last_page=1)
            image = pages[0]
        else:
            image = Image.open(image_path)

        # Build text candidates
        texts = [f"a product page showing {expected_product}"]
        if negative_examples:
            for neg in negative_examples:
                texts.append(f"a product page showing {neg}")
        else:
            # Default negative: generic wrong product
            texts.append("a product page showing a different product")
            texts.append("an error page or page not found")

        # Get similarities
        inputs = self.processor(
            text=texts,
            images=image,
            return_tensors="pt",
            padding=True
        ).to(self.device)

        with torch.no_grad():
            outputs = self.model(**inputs)
            logits = outputs.logits_per_image[0]
            probs = logits.softmax(dim=0)

        # Build results
        results = {
            "expected_product": expected_product,
            "match_probability": float(probs[0]),
            "is_correct": bool(probs[0] > 0.5),
            "all_scores": {text: float(prob) for text, prob in zip(texts, probs)}
        }

        return results


def main():
    if len(sys.argv) < 3:
        print("Usage: python clip_similarity.py <image_path> <expected_product>")
        print("Example: python clip_similarity.py screenshot.pdf 'AirPods Pro wireless earbuds'")
        sys.exit(1)

    image_path = Path(sys.argv[1])
    expected_product = sys.argv[2]

    if not image_path.exists():
        print(f"Error: File not found: {image_path}")
        sys.exit(1)

    verifier = ProductVerifier()
    result = verifier.verify(
        image_path,
        expected_product,
        negative_examples=["Nokia phone case", "phone accessories", "unrelated product"]
    )

    print(f"\nVerification for: {image_path.name}")
    print(f"Expected: {expected_product}")
    print(f"\nResult: {'CORRECT' if result['is_correct'] else 'WRONG PRODUCT'}")
    print(f"Match probability: {result['match_probability']:.1%}")
    print(f"\nAll scores:")
    for text, score in result['all_scores'].items():
        marker = " <--" if "expected" not in text and score > result['match_probability'] else ""
        print(f"  {score:.1%}: {text}{marker}")


if __name__ == "__main__":
    main()
