# Databricks notebook source
# GOLD — five marts, each answering a question a merchandiser actually asks.
#
#   daily_sales       "how did we trade?"
#   top_products      "what is selling, and is it coming back?"
#   inventory_health  "what will we run out of?"
#   returns_analysis  "why are things coming back?"
#   size_curve        "are we broken on sizes?"
#
# Shaped for reading, not for storage: pre-joined, pre-aggregated, small. A gold
# table that needs a join to be useful is a silver table with ambition.

from pyspark.sql import Window
from pyspark.sql import functions as F

dbutils.widgets.text("catalog", "dev")
CATALOG = dbutils.widgets.get("catalog")

sales = spark.read.table(f"{CATALOG}.silver.sales")
returns = spark.read.table(f"{CATALOG}.silver.returns")
inventory = spark.read.table(f"{CATALOG}.silver.inventory")
products = spark.read.table(f"{CATALOG}.bronze.products")
stores = spark.read.table(f"{CATALOG}.bronze.stores")

enriched = sales.join(products, "sku").join(stores, "store_id")

# --- 1. daily_sales ---------------------------------------------------------
#
# Margin, not just revenue. A day that hits its revenue target on 50% markdown
# is a bad day, and revenue alone will never tell you that.
daily_sales = (
    enriched.groupBy("sale_date", "category", "channel")
    .agg(
        F.sum("quantity").alias("units_sold"),
        F.sum("kept_quantity").alias("units_kept"),
        F.round(F.sum("gross_amount"), 2).alias("gross_amount"),
        F.round(F.sum("discount_amount"), 2).alias("discount_amount"),
        F.round(F.sum("net_revenue"), 2).alias("net_revenue"),
        F.round(F.sum(F.col("cost_price") * F.col("kept_quantity")), 2).alias("cost_of_goods"),
        F.countDistinct("transaction_id").alias("transactions"),
    )
    .withColumn("margin_amount", F.round(F.col("net_revenue") - F.col("cost_of_goods"), 2))
    .withColumn(
        "margin_pct",
        F.round(F.when(F.col("net_revenue") > 0, F.col("margin_amount") / F.col("net_revenue") * 100).otherwise(0), 1),
    )
    .withColumn(
        "discount_pct",
        F.round(F.when(F.col("gross_amount") > 0, F.col("discount_amount") / F.col("gross_amount") * 100).otherwise(0), 1),
    )
    .orderBy("sale_date", "category")
)

# --- 2. top_products --------------------------------------------------------
#
# At STYLE level, not SKU. Merchandisers reorder styles; sizes are a separate
# decision handled by the size curve mart below.
returns_by_style = (
    returns.join(products.select("sku", "style_id"), "sku")
    .groupBy("style_id")
    .agg(F.sum("quantity").alias("returned_units"))
)

top_products = (
    enriched.groupBy("style_id", "style_name", "category", "subcategory", "season")
    .agg(
        F.sum("quantity").alias("units_sold"),
        F.round(F.sum("net_revenue"), 2).alias("net_revenue"),
        F.round(F.sum(F.col("cost_price") * F.col("kept_quantity")), 2).alias("cost_of_goods"),
        F.round(F.avg("discount_pct") * 100, 1).alias("avg_discount_pct"),
        F.countDistinct("sku").alias("sku_count"),
    )
    .join(returns_by_style, "style_id", "left")
    .fillna({"returned_units": 0})
    .withColumn("margin_amount", F.round(F.col("net_revenue") - F.col("cost_of_goods"), 2))
    .withColumn(
        "return_rate_pct",
        F.round(F.when(F.col("units_sold") > 0, F.col("returned_units") / F.col("units_sold") * 100).otherwise(0), 1),
    )
    .withColumn("revenue_rank", F.row_number().over(Window.orderBy(F.desc("net_revenue"))))
    .orderBy("revenue_rank")
)

# --- 3. inventory_health ----------------------------------------------------
#
# DAYS OF COVER is the number that drives action: on-hand divided by daily sell
# rate. Stock levels alone are meaningless - 5 units is a crisis for a fast
# seller and a year of stock for a slow one.
latest_snapshot = inventory.agg(F.max("snapshot_date")).collect()[0][0]
window_start = F.date_sub(F.lit(latest_snapshot), 14)

sell_rate = (
    sales.filter(F.col("sale_date") >= window_start)
    .groupBy("sku", "store_id")
    .agg((F.sum("quantity") / 14.0).alias("daily_sell_rate"))
)

inventory_health = (
    inventory.filter(F.col("snapshot_date") == latest_snapshot)
    .join(sell_rate, ["sku", "store_id"], "left")
    .fillna({"daily_sell_rate": 0.0})
    .join(products.select("sku", "style_id", "style_name", "category", "size", "colour", "retail_price"), "sku")
    .join(stores.select("store_id", "store_name", "city"), "store_id")
    .withColumn(
        "days_of_cover",
        F.when(F.col("daily_sell_rate") > 0, F.round(F.col("on_hand") / F.col("daily_sell_rate"), 1)).otherwise(F.lit(None)),
    )
    .withColumn(
        "status",
        F.when(F.col("on_hand") == 0, "stockout")
        .when(F.col("days_of_cover") < 7, "critical")
        .when(F.col("days_of_cover") < 21, "low")
        .when(F.col("days_of_cover") > 90, "overstock")
        .otherwise("healthy"),
    )
    .withColumn("stock_value", F.round(F.col("on_hand") * F.col("retail_price"), 2))
    .select(
        "snapshot_date", "sku", "style_id", "style_name", "category", "colour", "size",
        "store_id", "store_name", "city", "on_hand", "on_order",
        F.round("daily_sell_rate", 2).alias("daily_sell_rate"),
        "days_of_cover", "status", "stock_value",
    )
)

# --- 4. returns_analysis ----------------------------------------------------
#
# Reason matters more than rate. A high return rate for "size" is a fit or size-
# chart problem you can fix; the same rate for "changed_mind" is the cost of
# doing business online.
sold_by_cat = enriched.groupBy("category").agg(F.sum("quantity").alias("units_sold"))

returns_analysis = (
    returns.join(products.select("sku", "category"), "sku")
    .groupBy("category", "reason")
    .agg(
        F.sum("quantity").alias("returned_units"),
        F.round(F.avg("days_to_return"), 1).alias("avg_days_to_return"),
    )
    .join(sold_by_cat, "category")
    .withColumn("return_rate_pct", F.round(F.col("returned_units") / F.col("units_sold") * 100, 2))
    .orderBy(F.desc("returned_units"))
)

# --- 5. size_curve ----------------------------------------------------------
#
# THE fashion-specific mart, and the one a generic retail model never produces.
#
# It compares the share of DEMAND a size takes against the share of STOCK it
# holds. When they diverge, you are simultaneously out of stock on the size
# people want and sitting on the size they do not - which looks fine at style
# level and is quietly destroying margin.
size_demand = (
    enriched.filter(F.col("size") != "OS")
    .groupBy("style_id", "style_name", "category", "size")
    .agg(F.sum("quantity").alias("units_sold"))
)

size_stock = (
    inventory.filter(F.col("snapshot_date") == latest_snapshot)
    .join(products.select("sku", "style_id", "size"), "sku")
    .groupBy("style_id", "size")
    .agg(F.sum("on_hand").alias("on_hand"))
)

style_window = Window.partitionBy("style_id")

size_curve = (
    size_demand.join(size_stock, ["style_id", "size"], "left")
    .fillna({"on_hand": 0})
    .withColumn("demand_share", F.round(F.col("units_sold") / F.sum("units_sold").over(style_window) * 100, 1))
    .withColumn(
        "stock_share",
        F.round(F.when(F.sum("on_hand").over(style_window) > 0, F.col("on_hand") / F.sum("on_hand").over(style_window) * 100).otherwise(0), 1),
    )
    .withColumn("imbalance", F.round(F.col("stock_share") - F.col("demand_share"), 1))
    .withColumn(
        "signal",
        F.when(F.col("imbalance") < -10, "under-stocked")
        .when(F.col("imbalance") > 10, "over-stocked")
        .otherwise("balanced"),
    )
    .orderBy("style_id", "size")
)

# --- write ------------------------------------------------------------------

for df, name in [
    (daily_sales, "daily_sales"),
    (top_products, "top_products"),
    (inventory_health, "inventory_health"),
    (returns_analysis, "returns_analysis"),
    (size_curve, "size_curve"),
]:
    df.write.mode("overwrite").option("overwriteSchema", "true").saveAsTable(f"{CATALOG}.gold.{name}")
    print(f"{CATALOG}.gold.{name}: {df.count()} rows")
