# Databricks notebook source
# SEED - simulate an upstream system dropping files into the landing zone.
#
# This exists only because samples.nyctaxi is a TABLE, and Auto Loader ingests
# FILES. In a real platform nothing like this runs: files arrive from an export
# job, a partner SFTP, an event capture sink, or a CDC tool.
#
# Each invocation writes ONE batch as JSON. Run it repeatedly with an increasing
# batch number to simulate new data arriving over time - that is what makes the
# incremental behaviour of Auto Loader visible rather than theoretical.

from pyspark.sql import functions as F

dbutils.widgets.text("landing_url", "")
dbutils.widgets.text("batch", "1")
dbutils.widgets.text("total_batches", "4")

LANDING = dbutils.widgets.get("landing_url").rstrip("/")
BATCH = int(dbutils.widgets.get("batch"))
TOTAL = int(dbutils.widgets.get("total_batches"))

TARGET = f"{LANDING}/taxi/batch={BATCH:02d}"

src = spark.read.table("samples.nyctaxi.trips")

# Deterministic slice by hash rather than by row_number.
#
# row_number() would need a global sort - a full shuffle of the dataset to
# produce something we then throw away. Hashing a few columns partitions the
# data with no shuffle at all, and it is stable: batch 3 is always the same rows,
# so re-running is idempotent.
part = src.filter(
    (F.abs(F.hash("tpep_pickup_datetime", "tpep_dropoff_datetime", "pickup_zip", "fare_amount")) % TOTAL)
    == (BATCH - 1)
)

# JSON deliberately, not Parquet.
#
# Parquet carries its own schema, which would make this too easy. JSON is
# schema-less on disk, so Auto Loader has to infer types, track schema drift, and
# rescue anything unexpected - which is the interesting part of the tool and the
# situation most landing zones are actually in.
part.write.mode("overwrite").json(TARGET)

print(f"batch {BATCH}/{TOTAL} -> {TARGET}")
print(f"rows: {part.count()}")
