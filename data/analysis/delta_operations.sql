-- Delta Lake operations against the tables this platform actually built.
--
-- Paste one query per notebook cell, %sql on the first line, attached to
-- lab01-single (infra/compute) or run them from a SQL warehouse.
--
-- ---------------------------------------------------------------------------
-- WHAT A DELTA TABLE IS
--
-- Parquet files plus a `_delta_log/` directory. The log is an ordered sequence
-- of JSON commits, each describing files ADDED and REMOVED. Reading a table
-- means replaying the log to work out which files are currently live.
--
-- Everything below follows from that one design:
--   - a write is one atomic commit, so readers never see half of it
--   - old versions exist because their files are still referenced by old commits
--   - time travel is just replaying the log to an earlier point
--   - VACUUM is what finally deletes files no live commit references
-- ---------------------------------------------------------------------------


-- 1. The transaction log, in human form.
--
-- One row per commit. bronze.sales is the interesting one: it is written by
-- Auto Loader, so you get a STREAMING UPDATE per micro-batch rather than one
-- WRITE per run. You may also see OPTIMIZE rows performed by "System-User",
-- which is predictive optimization doing maintenance nobody scheduled - and
-- which shows up on the bill.
--
-- operationMetrics is the column that earns its place: numOutputRows, numFiles,
-- numRemovedFiles. This is how you answer "what did that job actually do"
-- without instrumenting the job.
DESCRIBE HISTORY fashion.bronze.sales;


-- 2. Physical layout - the small-files problem, quantified.
--
-- numFiles against sizeInBytes is the number that matters. Auto Loader running
-- per daily drop produces many small files, and every query then pays to open
-- each one. The rule of thumb is ~1GB per file for scan-heavy tables; anything
-- in the kilobytes means metadata overhead dominates actual reading.
--
-- Expect this table to look bad. It is generated at lab scale, and seeing the
-- pathology clearly is more useful than hiding it behind more data.
DESCRIBE DETAIL fashion.bronze.sales;


-- 3. Time travel, and what it is actually for.
--
-- Not a party trick. This is the query you run at 3am when a number moved and
-- nobody knows why: read the table as it was BEFORE the run, and diff.
SELECT
  (SELECT COUNT(*) FROM fashion.bronze.sales VERSION AS OF 0) AS after_first_commit,
  (SELECT COUNT(*) FROM fashion.bronze.sales)                 AS now;


-- 4. Who changed what, per commit.
--
-- Joining history to metrics tells you whether a version added rows, rewrote
-- files, or did nothing but compact. Three very different events that all look
-- identical from the outside.
SELECT
  version,
  timestamp,
  operation,
  operationMetrics['numOutputRows']   AS rows_written,
  operationMetrics['numOutputBytes']  AS bytes_written,
  operationMetrics['numFiles']        AS files_written
FROM (DESCRIBE HISTORY fashion.silver.sales)
ORDER BY version;


-- 5. The quarantine tables, which are the point of the silver layer.
--
-- Rows are kept WITH the list of rules they broke, so this reads as a data
-- quality report rather than a mystery. An empty result is a healthy pipeline;
-- a growing one is an upstream conversation.
SELECT
  rule,
  COUNT(*) AS rows_failing
FROM (
  SELECT EXPLODE(_violations) AS rule FROM fashion.silver.sales_quarantine
)
GROUP BY rule
ORDER BY rows_failing DESC;


-- 6. OPTIMIZE with ZORDER, and when it is worth it.
--
-- OPTIMIZE compacts small files into large ones. ZORDER additionally co-locates
-- rows that share values in the named columns, so a filter on them reads fewer
-- files - Delta skips a file entirely when its min/max statistics rule it out.
--
-- Choose ZORDER columns by what your queries FILTER on, never by what they
-- group by. Here that is date and store, because every merchandising query is
-- scoped to a period and often to a location.
--
-- It is not free: it rewrites the table, which costs compute now to save
-- compute later. On a lab table it will not pay for itself. On a table queried
-- fifty times a day it pays for itself before lunch.
OPTIMIZE fashion.silver.sales ZORDER BY (sale_date, store_id);


-- 7. Did it help? Compare numFiles before and after.
DESCRIBE DETAIL fashion.silver.sales;


-- 8. VACUUM - the only thing that actually deletes data.
--
-- DRY RUN FIRST, always. It lists what would be removed without removing it.
--
-- RETAIN 168 HOURS is the default seven days, and it is a floor rather than a
-- suggestion: vacuum below the retention interval and a long-running reader
-- holding an older snapshot will fail mid-query with FileNotFound. Databricks
-- refuses shorter windows unless you disable the safety check, and the fact
-- that disabling it is possible is not an argument for doing it.
--
-- The tradeoff nobody states out loud: your time-travel window and your storage
-- bill are the same number. Seven days of history costs seven days of dead
-- files.
VACUUM fashion.silver.sales RETAIN 168 HOURS DRY RUN;


-- 9. The real thing. Commented out deliberately - read the dry run first.
-- VACUUM fashion.silver.sales RETAIN 168 HOURS;


-- 10. RESTORE, on a copy.
--
-- The reason to practise this on a scratch table is that RESTORE is itself a
-- commit: it does not rewind history, it appends a new version whose contents
-- match an old one. Nothing is lost, which is what makes it safe - and which
-- surprises people who expect the log to shrink.
CREATE OR REPLACE TABLE fashion.ops.orders_scratch
AS SELECT * FROM fashion.gold.daily_sales;

DELETE FROM fashion.ops.orders_scratch WHERE net_revenue > 10000;

SELECT COUNT(*) AS after_delete FROM fashion.ops.orders_scratch;

RESTORE TABLE fashion.ops.orders_scratch TO VERSION AS OF 0;

SELECT COUNT(*) AS after_restore FROM fashion.ops.orders_scratch;

-- The history now shows CREATE, DELETE and RESTORE as three separate commits.
DESCRIBE HISTORY fashion.ops.orders_scratch;

DROP TABLE fashion.ops.orders_scratch;


-- 11. The order book, which is the one table not produced by the pipeline.
--
-- Everything else in this catalog is derived and can be rebuilt from the landing
-- zone. These rows arrive from the storefront one checkout at a time and exist
-- nowhere else, which makes this the only table here where a bad VACUUM or a
-- careless DELETE actually loses information.
--
-- Note the file count against the row count. Delta commits per write, so a
-- handful of orders produces a handful of files - the small-files problem in its
-- purest form, and the clearest argument for why an order book belongs in an
-- operational database with change data capture into the lake.
SELECT status, COUNT(*) AS orders, ROUND(SUM(total), 0) AS value
FROM fashion.ops.orders
GROUP BY status
ORDER BY orders DESC;

DESCRIBE DETAIL fashion.ops.orders;
