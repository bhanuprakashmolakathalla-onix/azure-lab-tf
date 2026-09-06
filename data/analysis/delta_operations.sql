-- Delta Lake operations against the tables this platform actually built.
--
-- Paste one query per notebook cell, %sql on the first line, attached to
-- lab01-single.
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
-- One row per commit. You should see three WRITE operations on bronze - one per
-- pipeline run - and possibly OPTIMIZE rows performed by "System-User", which
-- is predictive optimization doing maintenance you did not schedule (Day 9's
-- largest line item).
--
-- operationMetrics is the interesting column: numOutputRows, numFiles,
-- numRemovedFiles. This is how you answer "what did that job actually do"
-- without instrumenting the job.
DESCRIBE HISTORY dev.bronze.taxi_trips;


-- 2. Physical layout - the small-files problem, quantified.
--
-- numFiles vs sizeInBytes is the number that matters. Auto Loader running
-- frequently produces many small files, and every query then pays to open each
-- one. The rule of thumb is ~1GB per file for scan-heavy tables; anything in the
-- kilobytes means metadata overhead dominates actual reading.
--
-- At this data volume the numbers are tiny and OPTIMIZE will not make queries
-- measurably faster. The point is to see the mechanism before it matters, not to
-- observe a speedup here.
DESCRIBE DETAIL dev.bronze.taxi_trips;


-- 3. Time travel by version.
--
-- NOTE version 0 is CREATE TABLE - schema only, zero rows. Schema and first
-- write are separate commits, so the first data version is 1. Worth knowing:
-- "restore to version 0" on a fresh table gives you an empty table, not the
-- original data.
SELECT
  (SELECT COUNT(*) FROM dev.bronze.taxi_trips VERSION AS OF 1) AS after_run1,
  (SELECT COUNT(*) FROM dev.bronze.taxi_trips VERSION AS OF 2) AS after_run2,
  (SELECT COUNT(*) FROM dev.bronze.taxi_trips)                 AS now;


-- 4. Time travel by timestamp.
--
-- More useful in practice than a version number, because incidents are reported
-- in wall-clock time: "the dashboard was wrong at 9am". Adjust the literal to a
-- point after your first run.
--
-- Bounded at BOTH ends. Too old and you get
-- DELTA_TIMESTAMP_EARLIER_THAN_COMMIT_RETENTION naming the earliest valid
-- timestamp; beyond log retention (30 days by default) the versions are gone.
--
-- It ERRORS rather than returning an empty result, which is the behaviour you
-- want - a system that silently returns zero rows for an out-of-range query
-- produces confidently wrong dashboards.
--
-- Adjust the literal to sit between two of your own commits.
SELECT COUNT(*) FROM dev.bronze.taxi_trips TIMESTAMP AS OF '2026-09-06T09:05:00';


-- 5. What changed between two versions.
--
-- The practical use of the log: not "what does the table say now" but "what did
-- that run add". Set the version numbers from query 1.
SELECT COUNT(*) AS rows_added_by_run3
FROM (
  SELECT * FROM dev.bronze.taxi_trips VERSION AS OF 3
  EXCEPT
  SELECT * FROM dev.bronze.taxi_trips VERSION AS OF 2
);


-- 6. OPTIMIZE with Z-ORDER.
--
-- Two distinct things in one command:
--
--   bin-packing - rewrite many small files into fewer large ones. Pure
--                 mechanical win, no thought required.
--
--   Z-ORDER     - co-locate rows with similar values in the same files, so that
--                 a filter on those columns can SKIP whole files. This is a real
--                 decision: choose columns you actually filter on, and no more
--                 than three or four. Z-ordering on a column nobody filters by
--                 costs a rewrite and buys nothing.
--
-- pickup_date because gold aggregates by it; pickup_zip because that is the
-- natural slice for any geographic question.
--
-- Note this is idempotent-ish: running it again on already-optimized data does
-- almost nothing, which is why predictive optimization can run it unattended.
OPTIMIZE dev.silver.taxi_trips ZORDER BY (pickup_date, pickup_zip);


-- 7. Confirm the layout changed.
--
-- numFiles should drop. Compare against what query 2 showed for silver.
DESCRIBE DETAIL dev.silver.taxi_trips;


-- 8. VACUUM - the one with teeth.
--
-- OPTIMIZE rewrote files but deleted nothing: the old small files are still on
-- disk, still referenced by older commits, which is what keeps time travel
-- working. VACUUM is what actually reclaims that storage.
--
-- DRY RUN first, always. It lists what WOULD be deleted.
VACUUM dev.silver.taxi_trips RETAIN 168 HOURS DRY RUN;


-- 9. Why the 7-day default exists, and why lowering it is dangerous.
--
-- 168 hours is the default retention. Databricks REFUSES a shorter window unless
-- you explicitly disable the safety check, and the reason is not conservatism:
--
--   - a long-running query that started before VACUUM can still be reading files
--     it is about to delete, and will fail mid-flight
--   - every version older than the window becomes unreadable, so time travel and
--     RESTORE silently lose their range
--
-- The correct response to "VACUUM is not freeing enough space" is almost never
-- to shorten retention. It is to check whether something is writing far more
-- versions than it should.
--
-- Left commented deliberately. Uncomment only to actually reclaim space.
-- VACUUM dev.silver.taxi_trips RETAIN 168 HOURS;


-- 10. RESTORE - undo, on a scratch copy.
--
-- Run against a copy, not a real table, because RESTORE is a real write: it
-- creates a NEW commit whose contents match the old version. It does not erase
-- history, it appends to it - so a restore is itself undoable, which is the
-- property you want at 3am.
CREATE OR REPLACE TABLE dev.bronze.taxi_scratch
AS SELECT * FROM dev.bronze.taxi_trips;

DELETE FROM dev.bronze.taxi_scratch WHERE fare_amount > 10;

SELECT COUNT(*) AS after_delete FROM dev.bronze.taxi_scratch;

RESTORE TABLE dev.bronze.taxi_scratch TO VERSION AS OF 0;

SELECT COUNT(*) AS after_restore FROM dev.bronze.taxi_scratch;

-- Note the history now shows the DELETE and the RESTORE as separate commits.
-- Nothing was lost; the log only ever grows.
DESCRIBE HISTORY dev.bronze.taxi_scratch;


-- 11. Clean up the scratch table.
DROP TABLE dev.bronze.taxi_scratch;
