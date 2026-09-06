# Databricks notebook source
# SILVER - conform, validate, and QUARANTINE.
#
# The previous version applied business rules as .filter() calls, which meant
# failing rows silently disappeared. That is the worst failure mode a pipeline
# has: if a source system starts emitting garbage, the pipeline gets QUIETER
# rather than louder, nothing alerts, and the dashboards still look plausible
# because the bad rows were never counted.
#
# This version keeps every row. Good rows go to silver, bad rows go to a
# quarantine table WITH THE REASON, and the counts are printed so a run can be
# judged rather than assumed.
#
# Databricks' managed equivalent is Lakeflow Declarative Pipelines (formerly DLT)
# with EXPECT / EXPECT OR DROP / EXPECT OR FAIL. Same idea, less code, and it
# ships the metrics into an event log for you. Doing it by hand once is worth it
# because the pattern transfers anywhere and the tradeoffs become visible.

from pyspark.sql import functions as F

dbutils.widgets.text("catalog", "dev")
CATALOG = dbutils.widgets.get("catalog")

SOURCE = f"{CATALOG}.bronze.taxi_trips"
TARGET = f"{CATALOG}.silver.taxi_trips"
QUARANTINE = f"{CATALOG}.silver.taxi_trips_quarantine"

# Rules are NAMED and declared in one place.
#
# The name is the point. "fare_positive" appears in the quarantine table, in the
# metrics, and in whatever alert eventually fires - so the person woken at 3am
# learns WHICH rule broke, not merely that the row count dropped.
#
# Each entry is (name, condition-that-must-be-TRUE-to-pass).
RULES = {
    # A trip that cost nothing is a meter error, not a free ride.
    "fare_positive": F.col("fare_amount") > 0,
    # Zero distance with a positive fare happens, but it is not a trip we can
    # reason about downstream.
    "distance_positive": F.col("trip_distance") > 0,
    # Dropoff before pickup is a clock problem. Never silently "fix" a timestamp.
    "chronological": F.col("tpep_dropoff_datetime") > F.col("tpep_pickup_datetime"),
    # Nulls in a join or grouping key poison every aggregate built on them.
    "has_pickup_zip": F.col("pickup_zip").isNotNull(),
}

bronze = spark.read.table(SOURCE)

# Collect the names of every rule a row FAILS, as an array.
#
# An array rather than a boolean: a row that breaks three rules is a different
# problem from one that breaks one, and if you only record the first failure you
# will fix it and immediately rediscover the second.
violations = F.array_compact(
    F.array(*[F.when(~cond, F.lit(name)).otherwise(F.lit(None)) for name, cond in RULES.items()])
)

checked = bronze.withColumn("_violations", violations)

clean = checked.filter(F.size("_violations") == 0).drop("_violations")
bad = checked.filter(F.size("_violations") > 0)

# --- Silver: conformed, valid rows ---------------------------------------
silver = (
    clean.withColumn(
        "trip_minutes",
        F.round((F.col("tpep_dropoff_datetime").cast("long") - F.col("tpep_pickup_datetime").cast("long")) / 60.0, 2),
    )
    .withColumn("pickup_date", F.to_date("tpep_pickup_datetime"))
    # No natural key in this dataset, so dedupe on the combination that should be
    # unique. Worth being explicit that this is an ASSUMPTION, not a guarantee.
    .dropDuplicates(["tpep_pickup_datetime", "tpep_dropoff_datetime", "pickup_zip", "dropoff_zip", "fare_amount"])
)

silver.write.mode("overwrite").option("overwriteSchema", "true").saveAsTable(TARGET)

# --- Quarantine: everything that failed, and why -------------------------
#
# APPEND, not overwrite. Quarantine is an audit trail - overwriting it would
# erase the evidence that yesterday's load was broken, which is precisely the
# thing you need when someone asks why last week's numbers moved.
(
    bad.withColumn("_quarantined_at", F.current_timestamp())
    .withColumn("_source_table", F.lit(SOURCE))
    .write.mode("append")
    .option("mergeSchema", "true")
    .saveAsTable(QUARANTINE)
)

# --- Metrics --------------------------------------------------------------
#
# Printed so the run is judgeable. In production these belong in a table with a
# threshold and an alert - a quarantine rate that jumps from 2% to 40% is an
# incident, and nobody discovers it by reading logs.
total = bronze.count()
kept = silver.count()
rejected = bad.count()

print(f"{SOURCE}: {total} rows in")
print(f"{TARGET}: {kept} kept")
print(f"{QUARANTINE}: {rejected} quarantined ({(rejected / total * 100) if total else 0:.2f}%)")
print()
print("violations by rule:")
(
    bad.select(F.explode("_violations").alias("rule"))
    .groupBy("rule")
    .count()
    .orderBy(F.desc("count"))
    .show(truncate=False)
)
