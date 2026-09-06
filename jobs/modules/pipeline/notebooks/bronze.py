# Databricks notebook source
# BRONZE - incremental ingestion with Auto Loader.
#
# This replaces the previous version, which read a table and overwrote bronze on
# every run. That was fine for a demo and wrong for a platform: reprocessing all
# history every night costs compute proportional to total data rather than to new
# data, and it destroys anything that arrived out of band.
#
# Auto Loader (format "cloudFiles") tracks which files it has already seen in a
# checkpoint, so each run processes ONLY new arrivals. Cost becomes proportional
# to what changed.
#
# The rule for bronze is unchanged: land it as-is, add provenance, fix nothing.

from pyspark.sql import functions as F

dbutils.widgets.text("catalog", "dev")
dbutils.widgets.text("landing_url", "")
dbutils.widgets.text("checkpoints_url", "")

CATALOG = dbutils.widgets.get("catalog")
LANDING = dbutils.widgets.get("landing_url").rstrip("/")
CHECKPOINTS = dbutils.widgets.get("checkpoints_url").rstrip("/")

SOURCE = f"{LANDING}/taxi"
TARGET = f"{CATALOG}.bronze.taxi_trips"

# Two DIFFERENT pieces of state, deliberately kept apart:
#
#   schema/  - the inferred schema and its evolution history
#   commits/ - which files have been processed
#
# They fail differently and are recovered differently. Delete commits/ and you
# reprocess everything (expensive, harmless). Delete schema/ and Auto Loader
# re-infers from whatever happens to be present, which can silently change column
# types. Keeping them in separate directories means you can nuke one without the
# other.
#
# Both live in the `checkpoints` container provisioned on Day 2 - deliberately
# NOT in a medallion layer, because this is operational state, not data.
SCHEMA_LOC = f"{CHECKPOINTS}/bronze_taxi/schema"
COMMIT_LOC = f"{CHECKPOINTS}/bronze_taxi/commits"

stream = (
    spark.readStream.format("cloudFiles")
    .option("cloudFiles.format", "json")
    .option("cloudFiles.schemaLocation", SCHEMA_LOC)
    # Without this, every JSON column arrives as a string - JSON has no types on
    # disk beyond string/number/bool, and the default is to keep everything as
    # text so nothing is ever lost to a bad guess.
    .option("cloudFiles.inferColumnTypes", "true")
    # Inference is a guess, and guesses on sparse data go wrong. Hints pin the
    # columns downstream code depends on, while leaving new/unknown columns free
    # to be inferred. This is the difference between "schema evolution works" and
    # "silver broke because fare_amount became a string".
    .option(
        "cloudFiles.schemaHints",
        "tpep_pickup_datetime TIMESTAMP, tpep_dropoff_datetime TIMESTAMP, "
        "trip_distance DOUBLE, fare_amount DOUBLE, pickup_zip INT, dropoff_zip INT",
    )
    # Anything that does not fit the schema lands in _rescued_data instead of
    # failing the run or being dropped. A pipeline that silently discards
    # malformed records is worse than one that stops.
    .option("cloudFiles.rescuedDataColumn", "_rescued_data")
    .load(SOURCE)
    # _metadata is a hidden column Spark exposes on file sources. Recording the
    # source file is what makes "where did this row come from" answerable a year
    # later, and it is free.
    .withColumn("_ingested_at", F.current_timestamp())
    .withColumn("_source_file", F.col("_metadata.file_path"))
)

# trigger(availableNow=True) is the important choice.
#
# This is a STREAM, but it is not a long-running one: it processes everything
# currently available, then stops. You get streaming's bookkeeping - exactly-once
# file tracking, checkpointed progress - on a batch schedule, with no cluster
# sitting idle between arrivals.
#
# A continuous trigger would mean paying for compute 24/7 to serve data that
# arrives a few times a day. For this lab that is the whole difference between
# ~Rs 2 per run and ~Rs 500 per day.
query = (
    stream.writeStream.option("checkpointLocation", COMMIT_LOC)
    .option("mergeSchema", "true")
    .trigger(availableNow=True)
    .toTable(TARGET)
)

query.awaitTermination()

progress = query.lastProgress
rows = progress["numInputRows"] if progress else 0
print(f"{TARGET}: {rows} new rows this run")
print(f"total rows now: {spark.read.table(TARGET).count()}")
