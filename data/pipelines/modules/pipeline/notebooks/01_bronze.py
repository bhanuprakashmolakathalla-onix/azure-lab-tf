# Databricks notebook source
# BRONZE — Auto Loader ingest of the three fact streams.
#
# ===========================================================================
# WHAT BRONZE IS FOR, AND WHAT IT IS NOT FOR
#
# Bronze is the landing zone made queryable. It does NOT clean, join, filter or
# reshape — every one of those decisions belongs in silver, where it is visible
# and testable. The only things added here are provenance columns, because once
# a file is ingested you can no longer ask the filesystem where a row came from.
#
# The temptation is always to "just fix this one obviously-broken field" during
# ingest. Resist it: a cleaning rule buried in bronze is invisible to anyone
# reading the silver notebook, and the quarantine counts in silver silently stop
# reflecting reality.
#
# ===========================================================================
# AUTO LOADER vs A PLAIN DIRECTORY READ
#
# spark.read.json(path) reads EVERYTHING, every run. Fine on day one, quadratic
# by day thirty, and it has no idea which files it has already seen.
#
# Auto Loader (cloudFiles) keeps a RocksDB record of processed files in the
# checkpoint, so a second run over the same directory ingests nothing. That is
# the entire value proposition and it is why the checkpoint location is not
# optional or disposable — delete it and the next run re-ingests the world,
# duplicating every row.
#
# GCP DELTA: the closest analogue is a Dataflow/Beam pipeline watching GCS with
# a state store, or BigQuery external tables plus a watermark you manage
# yourself. Auto Loader collapses that into a source option — but the state is
# still real state, living in a path you must keep.
#
# ===========================================================================
# WHY trigger(availableNow=True) AND NOT A CONTINUOUS STREAM
#
# This is written as a STREAM but run as a BATCH. availableNow processes every
# file that exists right now, in micro-batches, and then STOPS.
#
# That distinction is the practical one for cost: a continuous stream holds a
# cluster forever, and this is a lab on a budget. You keep exactly-once
# semantics and the file-tracking, and you pay only for the minutes you use.
# Switching to a real-time pipeline later is a one-line change to the trigger,
# with no rewrite — which is the actual argument for writing ingest as a stream
# even when you intend to run it on a schedule.
# ===========================================================================

from pyspark.sql import functions as F

dbutils.widgets.text("catalog", "fashion")
dbutils.widgets.text("landing_url", "")
dbutils.widgets.text("checkpoints_url", "")

CATALOG = dbutils.widgets.get("catalog")
LANDING = dbutils.widgets.get("landing_url").rstrip("/")
CHECKPOINTS = dbutils.widgets.get("checkpoints_url").rstrip("/")

if not LANDING or not CHECKPOINTS:
    raise ValueError("landing_url and checkpoints_url are required")

# ---------------------------------------------------------------------------
# SCHEMA HINTS, not a full schema.
#
# Two ways to give Auto Loader a schema, and the choice has consequences:
#
#   .schema(explicit)          inference off, evolution off. A new field in an
#                              upstream file is silently dropped — you find out
#                              months later when someone asks where it went.
#
#   cloudFiles.schemaHints     inference ON, with the types you care about
#                              pinned. New fields are picked up and recorded in
#                              the schema location.
#
# Hints exist because JSON inference is genuinely unreliable on exactly the
# fields that matter here. A quantity column whose sampled values happen to all
# be whole numbers infers as long; add one null-heavy file and it can land as
# string. Prices infer as double until a file contains "0" and they become long,
# at which point every downstream rounding calculation changes behaviour without
# erroring.
#
# So: pin the numerics, let everything else be discovered.
# ---------------------------------------------------------------------------
STREAMS = {
    "sales": "quantity INT, unit_price DOUBLE, list_price DOUBLE, discount_pct DOUBLE",
    "inventory": "on_hand INT, on_order INT",
    "returns": "quantity INT",
}


def ingest(stream: str, hints: str) -> None:
    source = f"{LANDING}/fashion/{stream}/"
    checkpoint = f"{CHECKPOINTS}/fashion/{stream}"
    target = f"{CATALOG}.bronze.{stream}"

    reader = (
        spark.readStream.format("cloudFiles")
        .option("cloudFiles.format", "json")
        # THE line that makes this Auto Loader rather than a directory read.
        # It holds the inferred schema AND the record of processed files.
        .option("cloudFiles.schemaLocation", checkpoint)
        .option("cloudFiles.schemaHints", hints)
        # Directory listing, not file notification. Notification mode creates an
        # Event Grid subscription and a storage queue — lower latency at scale,
        # more moving parts, and more resources to tear down. At this volume
        # listing is strictly better.
        .option("cloudFiles.useNotifications", "false")
        # The generator writes dt=YYYY-MM-DD directories. Naming the partition
        # column keeps it as a real column rather than letting it be inferred
        # inconsistently between streams.
        .option("cloudFiles.partitionColumns", "dt")
        # ANYTHING that does not fit the schema lands here instead of being
        # dropped or failing the batch. Without it, a malformed record is either
        # silently null or kills the run — both worse than a column you can
        # query. Silver treats a non-null _rescued_data as a quarantine signal.
        .option("rescuedDataColumn", "_rescued_data")
        .load(source)
    )

    # Provenance. Once a row is in a table, the filesystem context is gone —
    # _metadata is the only way back to which file produced it, and it is the
    # first thing anyone asks when a number looks wrong.
    enriched = (
        reader.withColumn("_source_file", F.col("_metadata.file_path"))
        .withColumn("_ingested_at", F.current_timestamp())
    )

    (
        enriched.writeStream.option("checkpointLocation", f"{checkpoint}/_commits")
        # availableNow: drain what exists, then stop. See the header.
        .trigger(availableNow=True)
        # mergeSchema so a genuinely new upstream field widens the table instead
        # of failing the write. Paired with schemaHints above, this is what makes
        # the layer tolerant of upstream change without being blind to it.
        .option("mergeSchema", "true")
        .toTable(target)
        .awaitTermination()
    )

    print(f"{target}: {spark.table(target).count()} rows total")


for name, hints in STREAMS.items():
    ingest(name, hints)

# ---------------------------------------------------------------------------
# RE-RUNNING THIS NOTEBOOK IS SAFE, and it is worth knowing exactly why.
#
# Auto Loader keys its processed-file record on the file PATH. The generator
# writes each day with mode("overwrite"), so a re-run replaces files at paths
# Auto Loader has already seen — and because cloudFiles.allowOverwrites defaults
# to false, those are NOT reprocessed. Same rows, no duplicates.
#
# Flip allowOverwrites to true and re-running the generator DOES duplicate every
# row, because the write below is an append with no merge key. That is the
# correct behaviour for a bronze layer (it is a log of what arrived, not a
# deduplicated view) and it is why silver, not bronze, is where identity is
# resolved.
#
# The way to genuinely start over is to delete the checkpoint AND drop the
# tables. Deleting only one of the two is the classic half-reset that produces
# either duplicates or a stubbornly empty table.
# ---------------------------------------------------------------------------
print()
print(f"bronze layer ready in {CATALOG}.bronze")
