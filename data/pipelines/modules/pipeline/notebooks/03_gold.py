# Databricks notebook source
# GOLD — seven marts with two different jobs.
#
# FIVE answer a question a merchandiser asks:
#
#   daily_sales       "how did we trade?"
#   top_products      "what is selling, and is it coming back?"
#   inventory_health  "what will we run out of?"
#   returns_analysis  "why are things coming back?"
#   size_curve        "are we broken on sizes?"
#
# TWO serve the storefront, at the grain a shopper thinks in:
#
#   product_catalog   one row per SKU   — price and availability per size
#   style_catalog     one row per style x colour — one row per thing you click
#
# Shaped for reading, not for storage: pre-joined, pre-aggregated, small. A gold
# table that needs a join to be useful is a silver table with ambition. The
# storefront marts push that further and are sized to fit in the app's memory,
# so browsing never queries anything.

from pyspark.sql import Window
from pyspark.sql import functions as F

dbutils.widgets.text("catalog", "fashion")
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
    # NULL IS NOT A SMALL CASE HERE, and getting it wrong inverted the mart.
    #
    # days_of_cover is null whenever daily_sell_rate is zero, and in SQL every
    # comparison against null is null - never true, never false. So a line with
    # stock and no sales at all failed `< 7`, failed `< 21`, failed `> 90`, and
    # fell through to `otherwise("healthy")`. The single worst state in the
    # inventory - money sitting on a shelf that nothing is pulling - was being
    # reported as the best one, and reported for a lot of lines.
    #
    # Dead stock gets its own status rather than being folded into overstock:
    # overstock is a line selling too slowly, dead is a line not selling, and
    # they call for different actions - markdown versus transfer or write-off.
    .withColumn(
        "status",
        F.when(F.col("on_hand") == 0, "stockout")
        .when(F.col("daily_sell_rate") <= 0, "dead")
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

# ===========================================================================
# THE STOREFRONT MARTS
#
# Everything above answers a question a merchandiser asks once a day. The two
# below serve a web page, on request, and that is a different design problem:
#
#   - the grain is what a SHOPPER thinks a product is, which is a style in one
#     colour, not a style and not a SKU
#   - every field the page needs must already be here, because the storefront
#     will not join anything at request time
#   - it has to be SMALL enough to hold in the app's memory, so browsing and
#     filtering never touch the warehouse at all
#
# That last one is the whole performance story of the shop. A few hundred rows
# fit in a process; a SQL round trip per page view does not fit in a budget.
# ===========================================================================

latest_sale_date = sales.agg(F.max("sale_date")).collect()[0][0]

# --- 6. product_catalog (SKU grain) -----------------------------------------
#
# CURRENT PRICE IS MODELLED AT STYLE LEVEL, not SKU level, because markdown is a
# style decision - a buyer discounts "the navy midi", never "the navy midi in M".
# Averaging the last week of actual selling prices recovers that decision from
# the transactions rather than re-deriving the generator's formula, which is what
# a real platform has to do: the discount that was applied is a fact, and the
# rule that produced it usually lives in a system you cannot see.
recent_cut = F.date_sub(F.lit(latest_sale_date), 7)

style_markdown = (
    sales.filter(F.col("sale_date") >= recent_cut)
    .join(products.select("sku", "style_id"), "sku")
    .groupBy("style_id")
    .agg(F.avg("discount_pct").alias("markdown"))
)

sku_demand = sales.groupBy("sku").agg(F.sum("quantity").alias("units_sold"))
sku_returns = returns.groupBy("sku").agg(F.sum("quantity").alias("returned_units"))

sku_stock = (
    inventory.filter(F.col("snapshot_date") == latest_snapshot)
    .groupBy("sku")
    .agg(F.sum("on_hand").alias("on_hand"))
)

# product_id is the URL key, and it is deliberately DERIVED rather than invented.
# The generator builds a SKU as style-colour-size, so style + the first three
# letters of the colour reproduces the SKU prefix exactly. The shop can therefore
# turn a chosen size into a SKU by string concatenation, with no lookup, and any
# SKU can be traced back to the page that sold it.
product_catalog = (
    products.join(style_markdown, "style_id", "left")
    .join(sku_demand, "sku", "left")
    .join(sku_returns, "sku", "left")
    .join(sku_stock, "sku", "left")
    .fillna({"markdown": 0.0, "units_sold": 0, "returned_units": 0, "on_hand": 0})
    .withColumn("product_id", F.concat_ws("-", F.col("style_id"), F.upper(F.substring(F.col("colour"), 1, 3))))
    .withColumn("list_price", F.round(F.col("retail_price"), 0))
    .withColumn("current_price", F.round(F.col("retail_price") * (1 - F.col("markdown")), 0))
    .withColumn("discount_pct", F.round(F.col("markdown") * 100, 0))
    .withColumn(
        "return_rate_pct",
        F.round(F.when(F.col("units_sold") > 0, F.col("returned_units") / F.col("units_sold") * 100).otherwise(0), 1),
    )
    .select(
        "sku", "product_id", "style_id", "style_name", "category", "subcategory",
        "colour", "size", "season", "list_price", "current_price", "discount_pct",
        "on_hand", "units_sold", "return_rate_pct", "launch_date",
    )
)

# --- 7. style_catalog (style x colour grain) --------------------------------
#
# One row per thing a shopper can click. Sizes collapse into two arrays: what
# exists and what is actually buyable. Keeping BOTH is what lets the page grey
# out a sold-out size instead of hiding it, which is the difference between "we
# do not make that" and "we are out of that" - a distinction customers notice.
SIZE_RANK = F.expr("""
    CASE size
      WHEN 'OS' THEN 0
      WHEN 'XS' THEN 1 WHEN 'S' THEN 2 WHEN 'M' THEN 3 WHEN 'L' THEN 4 WHEN 'XL' THEN 5
      ELSE CAST(size AS INT)
    END
""")

style_catalog = (
    product_catalog.withColumn("size_rank", SIZE_RANK)
    .groupBy("product_id", "style_id", "style_name", "category", "subcategory", "colour", "season")
    .agg(
        F.max("list_price").alias("list_price"),
        F.max("current_price").alias("current_price"),
        F.max("discount_pct").alias("discount_pct"),
        F.sum("on_hand").alias("on_hand"),
        F.sum("units_sold").alias("units_sold"),
        F.round(F.avg("return_rate_pct"), 1).alias("return_rate_pct"),
        F.max("launch_date").alias("launch_date"),
        # collect_list drops nulls, so the `when` with no otherwise is the
        # filter. sort_array orders by the struct's FIRST field, which is why
        # the rank is in there at all.
        F.sort_array(F.collect_list(F.when(F.col("on_hand") > 0, F.struct("size_rank", "size")))).alias("_buyable"),
        F.sort_array(F.collect_list(F.struct("size_rank", "size"))).alias("_all"),
    )
    .withColumn("sizes_in_stock", F.expr("transform(_buyable, x -> x.size)"))
    .withColumn("sizes_all", F.expr("transform(_all, x -> x.size)"))
    .drop("_buyable", "_all")
    .withColumn("in_stock", F.col("on_hand") > 0)
    .withColumn("is_new", F.datediff(F.lit(latest_sale_date), F.col("launch_date")) <= 30)
    # An unpartitioned window funnels every row through one task. That is a real
    # anti-pattern at scale and completely fine at this one - there are a few
    # hundred rows, and the alternative is ranking in the application on every
    # page load.
    .withColumn("popularity_rank", F.row_number().over(Window.orderBy(F.desc("units_sold"), F.asc("product_id"))))
    .orderBy("popularity_rank")
)

# --- write ------------------------------------------------------------------

for df, name in [
    (daily_sales, "daily_sales"),
    (top_products, "top_products"),
    (inventory_health, "inventory_health"),
    (returns_analysis, "returns_analysis"),
    (size_curve, "size_curve"),
    (product_catalog, "product_catalog"),
    (style_catalog, "style_catalog"),
]:
    df.write.mode("overwrite").option("overwriteSchema", "true").saveAsTable(f"{CATALOG}.gold.{name}")
    print(f"{CATALOG}.gold.{name}: {df.count()} rows")
