-- Cost attribution against Unity Catalog system tables.
--
-- Paste these into a notebook attached to lab01-single, one query per cell,
-- with %sql as the first line of each cell (or set the notebook language to SQL).
--
-- These are kept in the repo rather than typed ad-hoc because cost questions
-- recur, and the joins below are the fiddly part. Nobody should re-derive the
-- list_prices join under time pressure during a budget review.
--
-- ---------------------------------------------------------------------------
-- WHAT system.billing.usage IS
--
-- One row per (resource, sku, hour) of consumption, account-wide, across every
-- workspace. It is the same data behind the Azure bill, but sliced by DATABRICKS
-- concepts - job, cluster, warehouse, SKU - which the Azure portal cannot do.
--
-- Note the units: usage_quantity is DBUs, NOT money. DBUs become currency only
-- via system.billing.list_prices, which is a slowly-changing dimension keyed on
-- time. That join is the thing people get wrong.
-- ---------------------------------------------------------------------------


-- 1. Does the data exist at all, and how fresh is it?
--
-- Run this first. Billing records land with LATENCY - usually a few hours, and
-- occasionally longer. An empty result here means wait, not misconfiguration.
SELECT
  MIN(usage_date)             AS earliest,
  MAX(usage_date)             AS latest,
  COUNT(*)                    AS rows,
  COUNT(DISTINCT sku_name)    AS distinct_skus,
  ROUND(SUM(usage_quantity),3) AS total_dbus
FROM system.billing.usage;


-- 2. Spend by day and SKU, in real money.
--
-- The join is the interesting part. list_prices is time-versioned: a price row
-- has a start and (nullable) end, so a usage row must be matched to the price
-- that was in effect WHEN IT WAS CONSUMED. Joining on sku_name alone silently
-- multiplies rows once a price changes, and the number looks plausible.
--
-- pricing is a STRUCT; .default is list price. Any negotiated discount is not
-- represented here, so treat this as an upper bound.
SELECT
  u.usage_date,
  u.sku_name,
  ROUND(SUM(u.usage_quantity), 3)                        AS dbus,
  ROUND(SUM(u.usage_quantity * p.pricing.default), 4)    AS usd,
  ROUND(SUM(u.usage_quantity * p.pricing.default) * 88, 2) AS inr_approx
FROM system.billing.usage u
JOIN system.billing.list_prices p
  ON  u.cloud    = p.cloud
  AND u.sku_name = p.sku_name
  AND u.usage_start_time >= p.price_start_time
  AND (p.price_end_time IS NULL OR u.usage_start_time < p.price_end_time)
GROUP BY u.usage_date, u.sku_name
ORDER BY u.usage_date DESC, usd DESC;


-- 3. Cost per JOB - the question a platform team is actually asked.
--
-- usage_metadata is a struct carrying the Databricks object behind each row:
-- job_id, job_run_id, cluster_id, warehouse_id, node_type and so on. This is
-- what the Azure cost blade cannot tell you - Azure sees VMs in a managed
-- resource group with opaque names, not "the medallion pipeline".
SELECT
  u.usage_metadata.job_id,
  COUNT(DISTINCT u.usage_metadata.job_run_id)          AS runs,
  ROUND(SUM(u.usage_quantity), 3)                      AS dbus,
  ROUND(SUM(u.usage_quantity * p.pricing.default), 4)  AS usd
FROM system.billing.usage u
JOIN system.billing.list_prices p
  ON  u.cloud    = p.cloud
  AND u.sku_name = p.sku_name
  AND u.usage_start_time >= p.price_start_time
  AND (p.price_end_time IS NULL OR u.usage_start_time < p.price_end_time)
WHERE u.usage_metadata.job_id IS NOT NULL
GROUP BY u.usage_metadata.job_id
ORDER BY usd DESC;


-- 4. Attribution by TAG.
--
-- custom_tags on a usage row is where a tagging strategy pays off - or does not.
-- Recall the Day 6 discovery: Azure propagates a Databricks workspace's RESOURCE
-- tags onto its clusters as DEFAULT tags. So purpose/owner/autodelete should
-- appear here for free, without any cluster-level tagging.
--
-- If a row has no useful tags, that spend is UNATTRIBUTABLE - and unattributable
-- spend is the entire problem tagging exists to solve. In a real org this query
-- is how you find the 30% of the bill nobody owns.
SELECT
  u.custom_tags['purpose'] AS purpose,
  u.custom_tags['owner']   AS owner,
  u.billing_origin_product,
  ROUND(SUM(u.usage_quantity), 3)                     AS dbus,
  ROUND(SUM(u.usage_quantity * p.pricing.default), 4) AS usd
FROM system.billing.usage u
JOIN system.billing.list_prices p
  ON  u.cloud    = p.cloud
  AND u.sku_name = p.sku_name
  AND u.usage_start_time >= p.price_start_time
  AND (p.price_end_time IS NULL OR u.usage_start_time < p.price_end_time)
GROUP BY 1, 2, 3
ORDER BY usd DESC;


-- 5. The startup-tax question, quantified.
--
-- Day 6 measured 351 seconds of cluster cold start against 63 seconds of actual
-- work - roughly 85% of the run spent booting. This asks the billing data
-- whether that shows up as money.
--
-- system.compute.clusters is a slowly-changing record of cluster configuration;
-- joining it to usage lets you separate all-purpose from job compute, which bill
-- at very different DBU rates for identical hardware.
-- WARNING, learned the hard way: system.compute.clusters is ALSO a
-- slowly-changing dimension - one row per CONFIGURATION CHANGE, not one row per
-- cluster. Joining it on cluster_id alone multiplies every usage row by the
-- number of times that cluster was edited.
--
-- The first version of this query did exactly that and reported 0.420 DBUs for
-- lab01-single when the true figure was 0.210. Precisely 2x, because the cluster
-- had been reconfigured once. Job clusters were unaffected - created once, never
-- edited - which is what makes the bug so easy to miss: the numbers that are
-- wrong are the ones you have no independent check on.
--
-- Same failure mode as joining list_prices on sku_name alone. Whenever a system
-- table has change_time or a validity window, assume MANY rows per entity until
-- proven otherwise, and collapse to one before joining.
WITH latest_cluster AS (
  SELECT cluster_id, cluster_name, cluster_source
  FROM (
    SELECT
      cluster_id,
      cluster_name,
      cluster_source,
      ROW_NUMBER() OVER (PARTITION BY cluster_id ORDER BY change_time DESC) AS rn
    FROM system.compute.clusters
  )
  WHERE rn = 1
)
SELECT
  c.cluster_source,
  c.cluster_name,
  ROUND(SUM(u.usage_quantity), 3)                     AS dbus,
  ROUND(SUM(u.usage_quantity * p.pricing.default), 4) AS usd
FROM system.billing.usage u
JOIN latest_cluster c
  ON u.usage_metadata.cluster_id = c.cluster_id
JOIN system.billing.list_prices p
  ON  u.cloud    = p.cloud
  AND u.sku_name = p.sku_name
  AND u.usage_start_time >= p.price_start_time
  AND (p.price_end_time IS NULL OR u.usage_start_time < p.price_end_time)
GROUP BY 1, 2
ORDER BY usd DESC;
