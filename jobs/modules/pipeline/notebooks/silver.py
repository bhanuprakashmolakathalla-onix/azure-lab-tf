# Databricks notebook source
# SILVER - conform, validate, deduplicate.
#
# This is where business rules live. Every filter here is a decision someone
# should be able to argue with, which is why they are written out explicitly
# rather than buried in a WHERE clause.

from pyspark.sql import functions as F

dbutils.widgets.text("catalog", "dev")
CATALOG = dbutils.widgets.get("catalog")

SOURCE = f"{CATALOG}.bronze.taxi_trips"
TARGET = f"{CATALOG}.silver.taxi_trips"

bronze = spark.read.table(SOURCE)

silver = (
    bronze
    # A trip that cost nothing or covered no distance is a meter error, not a trip.
    .filter(F.col("fare_amount") > 0)
    .filter(F.col("trip_distance") > 0)
    # Dropoff before pickup is a clock problem. Drop rather than "fix".
    .filter(F.col("tpep_dropoff_datetime") > F.col("tpep_pickup_datetime"))
    .withColumn(
        "trip_minutes",
        F.round((F.col("tpep_dropoff_datetime").cast("long") - F.col("tpep_pickup_datetime").cast("long")) / 60.0, 2),
    )
    .withColumn("pickup_date", F.to_date("tpep_pickup_datetime"))
    # No natural key in this dataset, so dedupe on the combination that should be
    # unique. Worth being explicit that this is an assumption.
    .dropDuplicates(["tpep_pickup_datetime", "tpep_dropoff_datetime", "pickup_zip", "dropoff_zip", "fare_amount"])
)

silver.write.mode("overwrite").option("overwriteSchema", "true").saveAsTable(TARGET)

rejected = bronze.count() - silver.count()
print(f"{TARGET}: {silver.count()} rows kept, {rejected} rejected")
