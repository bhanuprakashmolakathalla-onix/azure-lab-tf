# Databricks notebook source
# SILVER — conform, validate, quarantine.
#
# Three fact streams land in bronze as raw JSON. Silver makes them trustworthy:
# correct types, valid references, business rules applied, and everything that
# fails kept with a reason rather than dropped.
#
# The join that matters here is returns-to-sales. A return arrives 2-12 days
# after the sale it belongs to, so "revenue" from the sales stream alone is
# always an overstatement. Silver is where that gets corrected, once, so no
# downstream consumer has to remember to.

from pyspark.sql import functions as F

dbutils.widgets.text("catalog", "fashion")
CATALOG = dbutils.widgets.get("catalog")

products = spark.read.table(f"{CATALOG}.bronze.products")
valid_skus = products.select("sku").distinct()

# ---------------------------------------------------------------------------
# Rules, named. The name reaches the quarantine table and any alert built on it.
# ---------------------------------------------------------------------------

# THE RULE EVERY STREAM SHARES.
#
# Auto Loader was told `rescuedDataColumn = _rescued_data` in bronze, so a field
# that did not fit the inferred schema is kept there instead of being dropped or
# killing the batch. Bronze deliberately does nothing with it - bronze is a log
# of what arrived.
#
# This is the promise bronze makes on silver's behalf, and until now silver was
# not keeping it: a non-null _rescued_data means the row parsed only partially,
# which is a data-quality failure whatever else about the row looks valid.
RESCUED_RULE = {"no_rescued_fields": F.col("_rescued_data").isNull()}


def quarantine(df, rules, target, source):
    """Split a dataframe on named rules. Good rows returned, bad rows persisted."""
    violations = F.array_compact(
        F.array(*[F.when(~cond, F.lit(name)).otherwise(F.lit(None)) for name, cond in rules.items()])
    )
    # CACHED, and it matters more than it looks. Below this line the same plan is
    # walked five times - two counts, a violation breakdown, the quarantine write
    # and the caller's own write - and without a cache Spark recomputes every
    # upstream join each time. On a single-node cluster that is most of the
    # notebook's runtime, spent re-deriving rows it already had.
    checked = df.withColumn("_violations", violations).cache()
    good = checked.filter(F.size("_violations") == 0).drop("_violations")
    bad = checked.filter(F.size("_violations") > 0)

    (
        bad.withColumn("_quarantined_at", F.current_timestamp())
        .withColumn("_source_table", F.lit(source))
        .write.mode("append")
        .option("mergeSchema", "true")
        .saveAsTable(target)
    )

    total, kept, rejected = checked.count(), good.count(), bad.count()
    print(f"{source}: {total} in, {kept} kept, {rejected} quarantined ({rejected / total * 100 if total else 0:.2f}%)")
    if rejected:
        bad.select(F.explode("_violations").alias("rule")).groupBy("rule").count().orderBy(F.desc("count")).show(truncate=False)
    return good


# --- sales ------------------------------------------------------------------

sales_raw = (
    spark.read.table(f"{CATALOG}.bronze.sales")
    .withColumn("sold_at", F.to_timestamp("sold_at"))
    .withColumn("sale_date", F.to_date("sold_at"))
    # Gross is what the list price would have earned; net_sale is what was
    # actually charged. Keeping both is what makes markdown analysable at all.
    .withColumn("gross_amount", F.round(F.col("list_price") * F.col("quantity"), 2))
    .withColumn("net_amount", F.round(F.col("unit_price") * F.col("quantity"), 2))
    .withColumn("discount_amount", F.round(F.col("gross_amount") - F.col("net_amount"), 2))
)

# An unknown SKU is a referential integrity failure, not a data-entry slip - it
# means the catalogue and the POS disagree, which is worth an alert.
sales_raw = sales_raw.join(valid_skus.withColumn("_sku_known", F.lit(True)), "sku", "left")

sales_rules = {
    **RESCUED_RULE,
    "known_sku": F.col("_sku_known").isNotNull(),
    "positive_quantity": F.col("quantity") > 0,
    "positive_price": F.col("unit_price") > 0,
    # A unit price above list means the discount was recorded backwards.
    "price_not_above_list": F.col("unit_price") <= F.col("list_price") * 1.001,
    "discount_within_bounds": (F.col("discount_pct") >= 0) & (F.col("discount_pct") <= 0.9),
}

sales = quarantine(sales_raw, sales_rules, f"{CATALOG}.silver.sales_quarantine", f"{CATALOG}.bronze.sales").drop("_sku_known")

# --- returns ----------------------------------------------------------------

returns_raw = (
    spark.read.table(f"{CATALOG}.bronze.returns")
    .withColumn("returned_at", F.to_date("returned_at"))
)

sale_keys = sales.select(F.col("transaction_id").alias("_txn"), F.col("sale_date").alias("_sale_date"))
returns_raw = returns_raw.join(sale_keys, returns_raw.transaction_id == F.col("_txn"), "left")

returns_rules = {
    **RESCUED_RULE,
    # An orphan return cannot be netted off anything, and silently dropping it
    # would overstate revenue - exactly the error this layer exists to prevent.
    "matched_to_sale": F.col("_txn").isNotNull(),
    "positive_quantity": F.col("quantity") > 0,
    # Returned before it was sold is a clock or keying error.
    "returned_after_sale": F.col("returned_at") >= F.col("_sale_date"),
}

returns = (
    quarantine(returns_raw, returns_rules, f"{CATALOG}.silver.returns_quarantine", f"{CATALOG}.bronze.returns")
    .withColumn("days_to_return", F.datediff("returned_at", "_sale_date"))
    .drop("_txn", "_sale_date")
)

# --- inventory --------------------------------------------------------------

inventory_raw = (
    spark.read.table(f"{CATALOG}.bronze.inventory")
    .withColumn("snapshot_date", F.to_date("snapshot_date"))
    .join(valid_skus.withColumn("_sku_known", F.lit(True)), "sku", "left")
)

inventory_rules = {
    **RESCUED_RULE,
    "known_sku": F.col("_sku_known").isNotNull(),
    "non_negative_on_hand": F.col("on_hand") >= 0,
    "non_negative_on_order": F.col("on_order") >= 0,
}

inventory = quarantine(
    inventory_raw, inventory_rules, f"{CATALOG}.silver.inventory_quarantine", f"{CATALOG}.bronze.inventory"
).drop("_sku_known")

# ---------------------------------------------------------------------------
# Net revenue: sales less what came back.
#
# Done ONCE, here, so no downstream table has to remember. A gold mart that
# joins returns itself is a gold mart that will eventually forget.
# ---------------------------------------------------------------------------

returned_per_txn = (
    returns.groupBy("transaction_id")
    .agg(F.sum("quantity").alias("returned_quantity"))
)

sales_net = (
    sales.join(returned_per_txn, "transaction_id", "left")
    .fillna({"returned_quantity": 0})
    .withColumn("kept_quantity", F.col("quantity") - F.col("returned_quantity"))
    .withColumn("returned_amount", F.round(F.col("unit_price") * F.col("returned_quantity"), 2))
    .withColumn("net_revenue", F.round(F.col("net_amount") - F.col("returned_amount"), 2))
)

for df, name in [(sales_net, "sales"), (returns, "returns"), (inventory, "inventory")]:
    df.write.mode("overwrite").option("overwriteSchema", "true").saveAsTable(f"{CATALOG}.silver.{name}")
    print(f"{CATALOG}.silver.{name}: {df.count()} rows")
