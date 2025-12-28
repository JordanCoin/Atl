#!/usr/bin/env python3
"""
CLI tool to verify product page matches expected product.
Returns JSON for easy integration with shell scripts.
"""

import json
import sys
from pathlib import Path

from PIL import Image
from pdf2image import convert_from_path
import torch
from transformers import CLIPProcessor, CLIPModel

# Cache model globally for repeated calls
_model = None
_processor = None
_device = None


def get_model():
    global _model, _processor, _device
    if _model is None:
        _device = "mps" if torch.backends.mps.is_available() else "cpu"
        _model = CLIPModel.from_pretrained("openai/clip-vit-base-patch32")
        _processor = CLIPProcessor.from_pretrained("openai/clip-vit-base-patch32")
        _model.to(_device)
        _model.training = False
    return _model, _processor, _device


def verify_product(image_path: str, expected_product: str, threshold: float = 0.4) -> dict:
    """Verify screenshot shows expected product."""
    model, processor, device = get_model()

    path = Path(image_path)
    if not path.exists():
        return {"error": f"File not found: {image_path}", "is_correct": False}

    # Load image
    if path.suffix.lower() == ".pdf":
        pages = convert_from_path(path, first_page=1, last_page=1)
        image = pages[0]
    else:
        image = Image.open(path)

    # Text candidates
    texts = [
        f"a product page showing {expected_product}",
        "a product page showing a different unrelated product",
        "an error page or wrong product",
    ]

    # Get similarities
    inputs = processor(text=texts, images=image, return_tensors="pt", padding=True).to(device)

    with torch.no_grad():
        outputs = model(**inputs)
        probs = outputs.logits_per_image[0].softmax(dim=0)

    match_prob = float(probs[0])
    is_correct = match_prob > threshold

    return {
        "is_correct": is_correct,
        "match_probability": round(match_prob, 3),
        "threshold": threshold,
        "expected_product": expected_product,
        "confidence": "high" if match_prob > 0.7 or match_prob < 0.2 else "medium" if match_prob > 0.5 or match_prob < 0.3 else "low"
    }


def main():
    if len(sys.argv) < 3:
        print(json.dumps({"error": "Usage: verify_product.py <image_path> <expected_product> [threshold]"}))
        sys.exit(1)

    image_path = sys.argv[1]
    expected_product = sys.argv[2]
    threshold = float(sys.argv[3]) if len(sys.argv) > 3 else 0.4

    result = verify_product(image_path, expected_product, threshold)
    print(json.dumps(result))


if __name__ == "__main__":
    main()
