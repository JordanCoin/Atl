# Cart Dataset Collection Prompt

Use this with ralph loop to collect diverse cart training data across merchants.

## Setup

Make sure ATL is running (`atl ping`) and the CLI is installed (`atl --version`).

## Instructions

You are collecting shopping cart training data. For each merchant below, you will build a cart with a specific item/quantity configuration, capture it, and append it to the dataset.

### Rules

1. **Navigate naturally** — start at the homepage, use marks to find products. Never guess URLs.
2. **Classify every page** — run `atl classify --json` after every navigation. This builds classifier training data.
3. **Dismiss popups first** — cookie banners, app prompts, newsletter modals. Look for: close, dismiss, no thanks, accept, got it, continue.
4. **Verify after every action** — run `atl pdftext --mark` after clicking to confirm state changed.
5. **Don't sign in** — we want guest cart experiences.
6. **Clear between merchants** — `atl reset --clear-cookies` between each merchant.

### Core loop for each cart

```
atl reset --clear-cookies
atl goto "<merchant URL>" --wait
atl classify --json
atl pdftext --mark

# Navigate to find the target product(s)
# Use marks to click through categories/search
# atl classify --json at each page

# On product page, add to cart
# Adjust quantity if needed
# Repeat for additional items

# Navigate to cart
atl classify --json
atl pdftext --mark          # verify it's a cart with items
atl unmark
atl pdf -o /tmp/cart.pdf

atl dataset append \
  --pdf /tmp/cart.pdf \
  --ground-truth '<JSON matching schema below>'
```

### Ground truth schema (run `atl dataset schema` for reference)

```json
{
  "merchant": "amazon",
  "url": "https://www.amazon.com/gp/cart/view.html",
  "items": [
    {
      "name": "Exact product name as shown on page",
      "quantity": 2,
      "unit_price": "$14.99",
      "total_price": "$29.98"
    }
  ],
  "subtotal": "$29.98",
  "tax": "$2.40",
  "total": "$32.38",
  "currency": "USD",
  "timestamp": "2026-03-05T00:00:00Z",
  "notes": "any relevant context"
}
```

**Important:** Copy prices EXACTLY as displayed (with `$`, commas, decimals). If tax or shipping aren't shown (common when not signed in), omit them. The `total` should be whatever the page shows as the final number — often just the subtotal for guest carts.

## Cart Configurations

Each row = one cart to collect. The goal is diversity in merchants, item counts, and quantities.

### Round 1: Single item, quantity 1 (baseline)

| # | Merchant | Category | Notes |
|---|----------|----------|-------|
| 1 | Amazon | Electronics | Cheap item under $20 |
| 2 | Target | Home/Kitchen | Any item |
| 3 | Walmart | Grocery/Household | Any item |
| 4 | Best Buy | Accessories | Cable, case, etc. |
| 5 | Costco | Snacks/Pantry | Any item |
| 6 | Home Depot | Tools/Hardware | Small item |
| 7 | Lowes | Garden/Outdoor | Small item |
| 8 | Kohls | Clothing | Any item |
| 9 | Macys | Home/Bed/Bath | Any item |
| 10 | Staples | Office Supplies | Any item |

### Round 2: Single item, quantity 2-5

| # | Merchant | Qty | Notes |
|---|----------|-----|-------|
| 11 | Amazon | 3 | Same cheap item, qty 3 |
| 12 | Target | 2 | Same category, qty 2 |
| 13 | Walmart | 5 | Grocery item, qty 5 |
| 14 | Best Buy | 2 | Accessory, qty 2 |
| 15 | Costco | 3 | Bulk item, qty 3 |

### Round 3: Multiple items, mixed quantities

| # | Merchant | Items | Notes |
|---|----------|-------|-------|
| 16 | Amazon | 2 items (qty 1 each) | Different categories |
| 17 | Amazon | 3 items (qty 1, 2, 1) | Mixed quantities |
| 18 | Target | 2 items (qty 1, 3) | One cheap, one mid-price |
| 19 | Walmart | 3 items (qty 1 each) | All different departments |
| 20 | Walmart | 4 items (qty 2, 1, 1, 3) | Big mixed cart |
| 21 | Best Buy | 2 items (qty 1, 1) | Electronics + accessory |
| 22 | Target | 3 items (qty 1, 1, 1) | Three different categories |
| 23 | Amazon | 5 items (qty 1 each) | Stress test — big cart |
| 24 | Walmart | 2 items (qty 5, 1) | One bulk, one single |
| 25 | Costco | 2 items (qty 1, 1) | Two different items |

### Round 4: Edge cases

| # | Merchant | Scenario | Notes |
|---|----------|----------|-------|
| 26 | Amazon | Item with active deal/coupon | Capture discount in ground truth |
| 27 | Target | Item on sale (was/now price) | Note both prices |
| 28 | Walmart | Item with shipping cost shown | Capture shipping |
| 29 | Best Buy | Item with protection plan added | Note add-ons |
| 30 | Amazon | Cart with out-of-stock warning | Note in ground truth |

### Round 5: Repeat favorites (more samples per merchant)

Repeat rounds 1-3 with DIFFERENT products from the same merchants. The goal is 8-10 samples per merchant minimum, covering different products and cart configurations.

## Tracking progress

After each collection session, run:
```
atl dataset list
atl dataset validate
```

Target: 50+ samples across 10+ merchants before evaluating model quality.

## If a merchant blocks you

Some sites (like Home Depot) may error on navigation. Skip them and move to the next. Don't waste time fighting bot detection — we'll revisit those later.

## If you get stuck

- Page won't load → `atl wait 3000` then `atl pdftext --mark`
- Can't find Add to Cart → `atl pdf -o /tmp/debug.pdf` and look at the visual
- Wrong page after click → `atl back --wait` and try a different label
- Modal/popup blocking → look for dismiss/close labels in the marks
