# Databricks notebook source
# BRONZE - land the source data as-is, plus provenance.
#
# The rule for bronze: do not clean, do not filter, do not fix. If the source is
# wrong, bronze should be wrong in exactly the same way, because bronze is what
# you replay from when a silver transform turns out to be a bug. The only things
# added are metadata columns describing WHERE and WHEN it arrived.

from pyspark.sql import functions as F

# Parameterised so this same notebook targets dev or prod. Nothing environment-
# specific is hardcoded - the JOB decides which catalog it writes to.
dbutils.widgets.text("catalog", "dev")
CATALOG = dbutils.widgets.get("catalog")

SOURCE = "samples.nyctaxi.trips"
TARGET = f"{CATALOG}.bronze.taxi_trips"

df = (
    spark.read.table(SOURCE)
    .withColumn("_ingested_at", F.current_timestamp())
    .withColumn("_source", F.lit(SOURCE))
)

df.write.mode("overwrite").option("overwriteSchema", "true").saveAsTable(TARGET)

print(f"{TARGET}: {df.count()} rows")
