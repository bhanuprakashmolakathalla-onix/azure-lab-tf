# Databricks notebook source
# SOURCE DATA GENERATOR — stands in for the systems a fashion retailer actually has.
#
# ===========================================================================
# THE DATA MODEL
#
# Two dimensions (reference data, full snapshot each run — this is how a master
# data system exports) and three fact streams (append-only file drops, which is
# how POS, WMS and returns systems export):
#
#   products    dimension   SKU catalogue. A SKU is style x colour x size.
#   stores      dimension   physical stores and online channels
#
#   sales       fact/daily  one row per line item sold
#   inventory   fact/daily  on-hand snapshot per SKU per store
#   returns     fact/daily  items coming back, with a reason
#
# The generator is DETERMINISTIC (fixed seed). Re-running produces identical
# data, so a pipeline bug is distinguishable from a data change — which is the
# whole reason not to use random data in a lab.
#
# ===========================================================================
# WHY THIS SHAPE, AND NOT A FLAT TABLE
#
# Fashion has three characteristics that generic retail examples miss, and they
# are what make the gold layer interesting:
#
#   SIZE CURVE      demand is not uniform across sizes. Selling out of M while
#                   XS sits on the shelf is the single most common way a fashion
#                   business loses margin, and it is invisible at style level.
#
#   MARKDOWN DECAY  price falls as a season ages. Revenue means nothing without
#                   knowing what was discounted, so every fact carries both the
#                   list price and what was actually paid.
#
#   RETURN RATES    vary enormously by category — dresses and trousers come back
#                   far more than accessories. Net revenue is the only honest
#                   number, and it needs returns joined to sales.
# ===========================================================================

import random
from datetime import date, timedelta

from pyspark.sql import functions as F
from pyspark.sql.types import (
    DateType,
    DoubleType,
    IntegerType,
    StringType,
    StructField,
    StructType,
    TimestampType,
)

dbutils.widgets.text("landing_url", "")
dbutils.widgets.text("catalog", "dev")
dbutils.widgets.text("start_date", "2026-08-01")
dbutils.widgets.text("num_days", "28")
dbutils.widgets.text("seed", "42")

LANDING = dbutils.widgets.get("landing_url").rstrip("/")
CATALOG = dbutils.widgets.get("catalog")
START = date.fromisoformat(dbutils.widgets.get("start_date"))
NUM_DAYS = int(dbutils.widgets.get("num_days"))
SEED = int(dbutils.widgets.get("seed"))

rng = random.Random(SEED)

# ---------------------------------------------------------------------------
# Reference data
# ---------------------------------------------------------------------------

CATEGORIES = {
    # category: (subcategories, base price range, return rate, size scheme)
    "Dresses": (["Midi", "Maxi", "Mini"], (2200, 6500), 0.28, "apparel"),
    "Tops": (["Shirt", "Blouse", "T-Shirt"], (900, 2800), 0.18, "apparel"),
    "Trousers": (["Chino", "Denim", "Formal"], (1800, 4500), 0.24, "apparel"),
    "Outerwear": (["Jacket", "Coat"], (4000, 12000), 0.15, "apparel"),
    "Footwear": (["Sneaker", "Heel", "Sandal"], (2500, 8000), 0.22, "shoe"),
    "Accessories": (["Bag", "Belt", "Scarf"], (700, 3500), 0.06, "onesize"),
}

SIZE_SCHEMES = {
    # Size curve: the SHARE of demand each size takes. Deliberately not uniform -
    # this asymmetry is the point, and gold surfaces it.
    "apparel": [("XS", 0.08), ("S", 0.20), ("M", 0.32), ("L", 0.26), ("XL", 0.14)],
    "shoe": [("38", 0.12), ("39", 0.18), ("40", 0.24), ("41", 0.22), ("42", 0.16), ("43", 0.08)],
    "onesize": [("OS", 1.0)],
}

COLOURS = ["Black", "Ivory", "Navy", "Olive", "Rust", "Sand", "Burgundy"]
SEASONS = ["SS26", "AW25"]

STORES = [
    ("ST01", "Bengaluru Indiranagar", "Bengaluru", "South", "retail"),
    ("ST02", "Bengaluru Koramangala", "Bengaluru", "South", "retail"),
    ("ST03", "Mumbai Bandra", "Mumbai", "West", "retail"),
    ("ST04", "Mumbai Lower Parel", "Mumbai", "West", "retail"),
    ("ST05", "Delhi Saket", "Delhi", "North", "retail"),
    ("ST06", "Delhi CP", "Delhi", "North", "retail"),
    ("ST07", "Hyderabad Jubilee", "Hyderabad", "South", "retail"),
    ("ST08", "Chennai Nungambakkam", "Chennai", "South", "retail"),
    ("ST09", "Pune Koregaon", "Pune", "West", "retail"),
    ("ST10", "Kolkata Park St", "Kolkata", "East", "retail"),
    ("ONL1", "Online IN", "-", "-", "online"),
    ("ONL2", "Online App", "-", "-", "online"),
]

# ---------------------------------------------------------------------------
# products — style x colour x size
# ---------------------------------------------------------------------------

products = []
style_seq = 0

for category, (subcats, (lo, hi), _return_rate, scheme) in CATEGORIES.items():
    for subcat in subcats:
        for _ in range(3):  # three styles per subcategory
            style_seq += 1
            style_id = f"STY{style_seq:04d}"
            style_name = f"{subcat} {rng.choice(['Classic', 'Relaxed', 'Tailored', 'Everyday'])}"
            season = rng.choice(SEASONS)
            retail = round(rng.uniform(lo, hi), -1)
            # Cost is 35-45% of retail. Margin is the number merchandisers manage.
            cost = round(retail * rng.uniform(0.35, 0.45), -1)
            launch = START - timedelta(days=rng.randint(10, 120))

            for colour in rng.sample(COLOURS, rng.randint(2, 4)):
                for size, _share in SIZE_SCHEMES[scheme]:
                    products.append(
                        (
                            f"{style_id}-{colour[:3].upper()}-{size}",
                            style_id,
                            style_name,
                            category,
                            subcat,
                            colour,
                            size,
                            season,
                            float(cost),
                            float(retail),
                            launch,
                        )
                    )

products_schema = StructType([
    StructField("sku", StringType()),
    StructField("style_id", StringType()),
    StructField("style_name", StringType()),
    StructField("category", StringType()),
    StructField("subcategory", StringType()),
    StructField("colour", StringType()),
    StructField("size", StringType()),
    StructField("season", StringType()),
    StructField("cost_price", DoubleType()),
    StructField("retail_price", DoubleType()),
    StructField("launch_date", DateType()),
])

products_df = spark.createDataFrame(products, products_schema)

stores_schema = StructType([
    StructField("store_id", StringType()),
    StructField("store_name", StringType()),
    StructField("city", StringType()),
    StructField("region", StringType()),
    StructField("channel", StringType()),
])
stores_df = spark.createDataFrame(STORES, stores_schema)

# Dimensions go straight to Delta as a FULL SNAPSHOT, not through Auto Loader.
#
# That is the honest modelling choice: a master data system exports the whole
# catalogue, and yesterday's version is not interesting. Facts are append-only
# and streamed; dimensions are replaced. Treating both the same way is a common
# and expensive mistake.
products_df.write.mode("overwrite").option("overwriteSchema", "true").saveAsTable(f"{CATALOG}.bronze.products")
stores_df.write.mode("overwrite").option("overwriteSchema", "true").saveAsTable(f"{CATALOG}.bronze.stores")

print(f"products: {products_df.count()} SKUs across {style_seq} styles")
print(f"stores:   {stores_df.count()}")

# ---------------------------------------------------------------------------
# Facts — written as dated JSON drops for Auto Loader to discover
# ---------------------------------------------------------------------------

# Lookup tables so generation does not need a join.
sku_meta = {
    p[0]: {
        "style_id": p[1],
        "category": p[3],
        "size": p[6],
        "retail": p[9],
        "launch": p[10],
    }
    for p in products
}
sku_list = list(sku_meta.keys())

# Weight SKU selection by its size's share of demand — this is what creates a
# realistic size curve rather than uniform noise.
size_share = {}
for category, (_s, _p, _r, scheme) in CATEGORIES.items():
    for size, share in SIZE_SCHEMES[scheme]:
        size_share[(category, size)] = share

sku_weights = [size_share.get((sku_meta[s]["category"], sku_meta[s]["size"]), 0.1) for s in sku_list]
return_rate = {c: v[2] for c, v in CATEGORIES.items()}

sales_rows, inventory_rows, returns_rows = [], [], []
txn_seq = 0
ret_seq = 0

# Opening stock, so inventory can deplete believably over the window.
on_hand = {(s, st[0]): rng.randint(4, 40) for s in sku_list for st in STORES if st[4] == "retail"}

for day_offset in range(NUM_DAYS):
    day = START + timedelta(days=day_offset)
    # Weekends sell roughly 60% more. Any real retail series has this shape and
    # a model that ignores it produces nonsense forecasts.
    weekend = day.weekday() >= 5
    volume = int(rng.gauss(240 if weekend else 150, 25))

    for _ in range(max(volume, 40)):
        txn_seq += 1
        sku = rng.choices(sku_list, weights=sku_weights, k=1)[0]
        meta = sku_meta[sku]
        store = rng.choice(STORES)
        qty = rng.choices([1, 1, 1, 2, 3], k=1)[0]

        # MARKDOWN DECAY: the older the style, the deeper the discount.
        age_days = (day - meta["launch"]).days
        base_discount = min(0.5, max(0.0, (age_days - 30) / 200))
        discount = round(base_discount + rng.uniform(-0.05, 0.10), 2)
        discount = min(max(discount, 0.0), 0.6)
        unit_price = round(meta["retail"] * (1 - discount), 2)

        sold_at = f"{day.isoformat()}T{rng.randint(9, 21):02d}:{rng.randint(0, 59):02d}:00"

        sales_rows.append(
            (
                f"TXN{txn_seq:08d}",
                sku,
                store[0],
                sold_at,
                qty,
                unit_price,
                float(meta["retail"]),
                round(discount, 2),
                f"CUST{rng.randint(1, 9000):05d}",
            )
        )

        if store[4] == "retail":
            key = (sku, store[0])
            on_hand[key] = max(0, on_hand.get(key, 0) - qty)

        # RETURNS: category-dependent, and they arrive a few days later - which
        # is exactly why net revenue cannot be computed from sales alone.
        if rng.random() < return_rate[meta["category"]]:
            lag = rng.randint(2, 12)
            returned_on = day + timedelta(days=lag)
            if returned_on <= START + timedelta(days=NUM_DAYS - 1):
                ret_seq += 1
                returns_rows.append(
                    (
                        f"RET{ret_seq:08d}",
                        f"TXN{txn_seq:08d}",
                        sku,
                        returned_on.isoformat(),
                        qty,
                        rng.choices(
                            ["size", "fit", "quality", "changed_mind", "damaged"],
                            weights=[40, 25, 10, 20, 5],
                            k=1,
                        )[0],
                    )
                )

    # Daily on-hand snapshot per retail store. Replenishment is deliberately
    # imperfect, so genuine stockouts appear in the data.
    for (sku, store_id), qty_left in on_hand.items():
        if rng.random() < 0.12:  # ~1 replenishment per SKU per 8 days
            qty_left = min(60, qty_left + rng.randint(5, 25))
            on_hand[(sku, store_id)] = qty_left
        inventory_rows.append((day.isoformat(), sku, store_id, qty_left, rng.choice([0, 0, 0, 10, 20])))


def write_drop(rows, schema, name, day_field_index):
    """One directory per day, so Auto Loader sees each day as a new arrival."""
    if not rows:
        return
    df = spark.createDataFrame(rows, schema)
    for day_offset in range(NUM_DAYS):
        day = (START + timedelta(days=day_offset)).isoformat()
        part = df.filter(F.col(schema.fieldNames()[day_field_index]).startswith(day))
        if part.limit(1).count() == 0:
            continue
        part.coalesce(1).write.mode("overwrite").json(f"{LANDING}/fashion/{name}/dt={day}")
    print(f"{name}: {df.count()} rows across {NUM_DAYS} daily drops")


sales_schema = StructType([
    StructField("transaction_id", StringType()),
    StructField("sku", StringType()),
    StructField("store_id", StringType()),
    StructField("sold_at", StringType()),
    StructField("quantity", IntegerType()),
    StructField("unit_price", DoubleType()),
    StructField("list_price", DoubleType()),
    StructField("discount_pct", DoubleType()),
    StructField("customer_id", StringType()),
])

inventory_schema = StructType([
    StructField("snapshot_date", StringType()),
    StructField("sku", StringType()),
    StructField("store_id", StringType()),
    StructField("on_hand", IntegerType()),
    StructField("on_order", IntegerType()),
])

returns_schema = StructType([
    StructField("return_id", StringType()),
    StructField("transaction_id", StringType()),
    StructField("sku", StringType()),
    StructField("returned_at", StringType()),
    StructField("quantity", IntegerType()),
    StructField("reason", StringType()),
])

write_drop(sales_rows, sales_schema, "sales", 3)
write_drop(inventory_rows, inventory_schema, "inventory", 0)
write_drop(returns_rows, returns_schema, "returns", 3)

print()
print(f"landing zone: {LANDING}/fashion/")
print("ready for Auto Loader")
