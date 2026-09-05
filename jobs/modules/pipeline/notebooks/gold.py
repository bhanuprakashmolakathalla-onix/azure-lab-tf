# Databricks notebook source
# GOLD - shaped for a consumer, not for storage.
#
# Gold tables answer a question. This one answers "what did each day look like",
# which is what a dashboard wants. Aggregation means it is small, fast, and
# cheap to query - the opposite trade-off from bronze.

from pyspark.sql import functions as F

dbutils.widgets.text("catalog", "dev")
CATALOG = dbutils.widgets.get("catalog")

SOURCE = f"{CATALOG}.silver.taxi_trips"
TARGET = f"{CATALOG}.gold.taxi_daily_summary"

gold = (
    spark.read.table(SOURCE)
    .groupBy("pickup_date")
    .agg(
        F.count("*").alias("trips"),
        F.round(F.avg("fare_amount"), 2).alias("avg_fare"),
        F.round(F.avg("trip_minutes"), 1).alias("avg_trip_minutes"),
        F.round(F.avg("trip_distance"), 2).alias("avg_distance"),
        F.round(F.sum("fare_amount"), 2).alias("total_revenue"),
    )
    .orderBy("pickup_date")
)

gold.write.mode("overwrite").option("overwriteSchema", "true").saveAsTable(TARGET)

print(f"{TARGET}: {gold.count()} days")
gold.show(10)
