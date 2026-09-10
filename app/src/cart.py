"""The shopping bag: a signed cookie, and nothing on the server.

===========================================================================
WHY THE BAG IS A COOKIE

The obvious alternative is a `carts` table. It is the wrong shape here for a
reason worth stating: every add-to-bag click would become a Delta commit, on a
serverless warehouse, for state that is thrown away far more often than it is
converted. Delta is a poor transactional store and a bag is the most
transactional thing a shop has.

Server-side sessions have the same problem one layer up - the app scales to zero
and runs up to two replicas, so "in memory" means "lost on the next request".

A cookie survives both, costs nothing, and needs no infrastructure to tear down.

===========================================================================
WHAT THE SIGNATURE IS AND IS NOT FOR

The cookie holds SKUs and quantities. It does NOT hold prices, names, or
totals - every one of those is looked up from the catalogue at render time. That
is the actual defence: a shopper editing their own cookie cannot make a dress
cost one rupee, because the cookie was never asked what the dress costs.

The HMAC is the second layer. Without it someone can still put a quantity of
nine million in their own bag and watch the arithmetic overflow into something
ugly. Signing makes the cookie tamper-EVIDENT; the quantity clamp below makes
tampering pointless anyway. Both, because the cheap one is cheap.

The secret comes from the environment and is the same across replicas. If it is
missing the process invents one, which means bags do not survive a restart - a
degradation, deliberately, rather than a fixed default key in a public repo.
"""

import base64
import hmac
import json
import logging
import os
import secrets
from hashlib import sha256

from . import db

log = logging.getLogger("meridian.cart")

COOKIE = "meridian_bag"
MAX_LINES = 20
MAX_QTY = 10

# Free delivery over this. A real threshold, because it changes what people put
# in the bag and the console's average order value should show that.
FREE_DELIVERY_OVER = 2999
DELIVERY_FEE = 149

_SECRET = os.getenv("CART_SECRET")
if not _SECRET:
    _SECRET = secrets.token_hex(32)
    log.warning("CART_SECRET not set - bags will not survive a restart or reach a second replica")
SECRET = _SECRET.encode()


def _sign(payload: bytes) -> str:
    return base64.urlsafe_b64encode(hmac.new(SECRET, payload, sha256).digest()).decode().rstrip("=")


def encode(items: list[dict]) -> str:
    payload = base64.urlsafe_b64encode(json.dumps(items, separators=(",", ":")).encode()).rstrip(b"=")
    return payload.decode() + "." + _sign(payload)


def decode(raw: str | None) -> list[dict]:
    if not raw or "." not in raw:
        return []
    payload, signature = raw.rsplit(".", 1)
    encoded = payload.encode()
    # compare_digest, not ==. String equality returns early on the first
    # differing byte, and the timing of that leak is exactly how a signature
    # gets guessed one character at a time.
    if not hmac.compare_digest(_sign(encoded), signature):
        log.warning("bag cookie failed signature check - discarding")
        return []
    try:
        padded = encoded + b"=" * (-len(encoded) % 4)
        items = json.loads(base64.urlsafe_b64decode(padded))
    except Exception:
        return []
    if not isinstance(items, list):
        return []

    clean = []
    for item in items[:MAX_LINES]:
        if not isinstance(item, dict):
            continue
        sku = str(item.get("sku") or "")[:64]
        try:
            qty = int(item.get("qty") or 0)
        except (TypeError, ValueError):
            continue
        if sku and 0 < qty <= MAX_QTY:
            clean.append({"sku": sku, "qty": qty})
    return clean


def add(items: list[dict], sku: str, qty: int = 1) -> list[dict]:
    qty = max(1, min(MAX_QTY, qty))
    for item in items:
        if item["sku"] == sku:
            item["qty"] = min(MAX_QTY, item["qty"] + qty)
            return items
    if len(items) >= MAX_LINES:
        return items
    return items + [{"sku": sku, "qty": qty}]


def set_quantity(items: list[dict], sku: str, qty: int) -> list[dict]:
    qty = max(0, min(MAX_QTY, qty))
    if qty == 0:
        return [i for i in items if i["sku"] != sku]
    for item in items:
        if item["sku"] == sku:
            item["qty"] = qty
    return items


def priced(items: list[dict]) -> dict:
    """Resolve a bag against the catalogue and cost it.

    Anything whose SKU has vanished from the catalogue is dropped rather than
    guessed at - a product pulled from sale between adding and checking out is a
    real case, and inventing a price for it is worse than losing the line.
    """
    cat = db.catalogue()

    lines, subtotal, units = [], 0.0, 0
    for item in items:
        row = cat["skus"].get(item["sku"])
        if not row:
            continue
        qty = item["qty"]
        unit = float(row["current_price"] or 0)
        # One definition of "available", in db.available, used everywhere. Both
        # lookups behind it are cached dictionaries, so calling it per line costs
        # nothing and keeps the product page and the bag from ever disagreeing
        # about whether the last one is still there.
        stock = db.available(item["sku"])
        line_total = round(unit * qty, 2)
        lines.append({
            **row,
            "quantity": qty,
            "line_total": line_total,
            "available": stock,
            "short": qty > stock,
        })
        subtotal += line_total
        units += qty

    subtotal = round(subtotal, 2)
    delivery = 0.0 if (subtotal >= FREE_DELIVERY_OVER or not lines) else float(DELIVERY_FEE)
    saved = round(sum((float(l["list_price"] or 0) - float(l["current_price"] or 0)) * l["quantity"] for l in lines), 2)

    return {
        "lines": lines,
        "items": units,
        "subtotal": subtotal,
        "delivery": delivery,
        "total": round(subtotal + delivery, 2),
        "saved": saved,
        "short": any(l["short"] for l in lines),
        "to_free_delivery": max(0.0, FREE_DELIVERY_OVER - subtotal) if lines else 0.0,
    }
