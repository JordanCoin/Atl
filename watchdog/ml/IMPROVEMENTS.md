# ML Improvements Roadmap

## 1. Better CLIP Prompts (Now - Free)

Instead of generic descriptions, use specific visual details:

```
GENERIC (current):
"Apple AirPods Pro wireless earbuds with charging case"

SPECIFIC (better):
"Apple AirPods Pro 2 white wireless earbuds, white MagSafe charging case, product photography, e-commerce listing"

NEGATIVE EXAMPLES (for contrast):
"phone case", "screen protector", "different headphones", "error page"
```

### Per-Store Prompt Templates:
- Amazon: "product image on white background, Prime badge, star rating"
- Best Buy: "product hero image, blue add to cart button, price in black"
- Target: "product on white, red Target branding, circle logo"
- Walmart: "product listing, blue Walmart styling, rollback badge"

## 2. Larger CLIP Model (Easy - ~15% better)

```python
# Current: 151M params, faster
"openai/clip-vit-base-patch32"

# Better: 428M params, more accurate
"openai/clip-vit-large-patch14"

# Best open model: Google SigLIP
"google/siglip-so400m-patch14-384"
```

## 3. Multi-Signal Ensemble (Medium)

Combine signals with learned weights:

```python
signals = {
    "clip_match": 0.949,           # Visual verification
    "title_match": 0.8,            # Title contains product name
    "price_in_range": 1.0,         # Price within expected range
    "selector_confidence": 0.475,  # Extraction confidence
    "domain_trust": 0.95,          # Known retailer domain
}

# Weighted combination (tune weights on data)
weights = {"clip": 0.35, "title": 0.25, "price": 0.2, "selector": 0.1, "domain": 0.1}
final_score = sum(signals[k] * weights[k] for k in weights)
```

## 4. Page Type Classifier (Medium)

Train classifier to detect: product, cart, checkout, search, error, login

Useful for:
- Detecting redirects to login pages
- Knowing when to look for cart total vs product price
- Identifying checkout flows

Training data needed: ~200 samples per class

## 5. Element Detection Model (Hard)

Fine-tune object detection to find:
- Price elements (bounding boxes)
- Add to Cart buttons
- Product images
- Out of stock badges

Could use: YOLO, Florence-2, or PaliGemma

## 6. OCR + Layout Understanding (Hard)

Extract structured data from screenshots:
- All visible prices with positions
- Button text and locations
- Product title text

Models: TrOCR, Donut, or PaddleOCR

## 7. Full Fine-tune CLIP (Hard - Best Results)

Once you have 1000+ samples:
- Contrastive learning on your domain
- Teach CLIP what "correct product page" means
- Domain-specific embeddings

---

## Data Collection Priorities

### High Value Samples:
1. **Wrong product redirects** - When site shows different product
2. **Out of stock pages** - Different layout, no buy button
3. **Cart pages** - Different structure than product pages
4. **Checkout pages** - Need to identify for automation
5. **Error/captcha pages** - Detect and handle gracefully

### Current Gap:
- 34 correct samples, only 2 wrong samples
- Need more negative examples for balanced training
- Run more automations on flaky sites (Target, Walmart redirect often)

---

## Quick Wins

1. [ ] Update CLIP prompts to be more specific
2. [ ] Add store-specific prompt templates
3. [ ] Switch to clip-vit-large-patch14
4. [ ] Collect 50+ "wrong product" samples
5. [ ] Add page type to workflow (product vs cart vs checkout)
