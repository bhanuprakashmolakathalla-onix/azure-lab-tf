"""Everything that talks to Databricks.

Both applications import this module and neither of them holds a credential:

    Container App  ->  user-assigned managed identity
                   ->  Entra token for the AzureDatabricks resource
                   ->  Databricks service principal (same application id)
                   ->  SQL warehouse
                   ->  fashion.gold.* and fashion.ops.*

No connection string, no personal access token, nothing in an environment
variable that would matter if it leaked. The identity IS the credential, it is
issued at runtime, and it expires on its own.

===========================================================================
THE PERFORMANCE DECISION, which is really a cost decision

A serverless SQL warehouse bills while it is RUNNING and stops when idle. A
storefront that queried it on every page view would keep it running all day and
still feel slow, because a warehouse round trip is tens of milliseconds at best
and ten seconds from cold.

So the product catalogue - a few hundred rows, changing only when the pipeline
runs - is loaded ONCE and held in memory. Browsing, filtering, sorting and
product pages are served entirely from that snapshot and touch nothing. The
warehouse is woken only by writes and by the ops console.

The cache is deliberately STALE-TOLERANT rather than merely time-limited. When
an entry expires, the page still renders from the old value and a background
thread fetches the new one. A shopper never waits on a refresh; they just see
numbers from a few minutes ago, which for stock counts is what they would see
anyway.
===========================================================================
"""

import logging
import os
import random
import string
import threading
import time
from contextlib import contextmanager
from datetime import date

from azure.identity import DefaultAzureCredential
from databricks import sql

log = logging.getLogger("meridian.db")

# The AzureDatabricks first-party application. This is the resource we ask Entra
# for a token for, and the id is the same in every tenant.
DATABRICKS_RESOURCE = "2ff814a6-3304-4ab8-85cb-cd0e6f879c1d"

SERVER_HOSTNAME = os.environ["DATABRICKS_SERVER_HOSTNAME"]
HTTP_PATH = os.environ["DATABRICKS_HTTP_PATH"]
CATALOG = os.getenv("CATALOG", "fashion")

CATALOG_TTL = int(os.getenv("CATALOG_TTL_SECONDS", "600"))
RESERVED_TTL = int(os.getenv("RESERVED_TTL_SECONDS", "120"))
ORDERS_TTL = int(os.getenv("ORDERS_TTL_SECONDS", "15"))
ANALYTICS_TTL = int(os.getenv("ANALYTICS_TTL_SECONDS", "300"))

# DefaultAzureCredential walks a chain: environment, then managed identity, then
# the Azure CLI. That is why this file runs unchanged in the Container App (where
# it finds the managed identity) and on the jumpbox (where it finds `az login`).
#
# The explicit client id matters: a Container App can have several identities
# assigned, and without naming one the credential has to guess.
CREDENTIAL = DefaultAzureCredential(
    managed_identity_client_id=os.getenv("AZURE_CLIENT_ID"),
    exclude_interactive_browser_credential=True,
)

ORDER_STATUSES = ["placed", "packed", "shipped", "delivered", "cancelled"]
NEXT_STATUS = {"placed": "packed", "packed": "shipped", "shipped": "delivered"}


# ---------------------------------------------------------------------------
# Connections
# ---------------------------------------------------------------------------


@contextmanager
def session():
    """One connection, reused for every query on one page render.

    Pooling ACROSS requests would be the obvious optimisation and is the wrong
    call: a serverless warehouse auto-stops when idle, so a pool of open
    connections is a pool of things keeping it awake and billing. Reconnecting
    costs milliseconds once the warehouse is running; keeping it running costs
    money continuously.

    Pooling WITHIN a request is free and worth having - the console's overview
    runs six queries, and six handshakes is five too many.
    """
    token = CREDENTIAL.get_token(f"{DATABRICKS_RESOURCE}/.default").token
    connection = sql.connect(
        server_hostname=SERVER_HOSTNAME,
        http_path=HTTP_PATH,
        access_token=token,
    )
    try:
        yield connection
    finally:
        connection.close()


def rows(conn, statement: str, params: dict | None = None) -> list[dict]:
    """Run one statement on an open connection and return dicts.

    Parameters are passed to the driver as PARAMETERS, never interpolated. The
    read paths here mostly take no user input, but the order write does, and one
    code path that formats SQL with f-strings is all it takes for the next
    person to copy the wrong pattern.
    """
    with conn.cursor() as cur:
        cur.execute(statement, params or {})
        if cur.description is None:
            return []
        cols = [c[0] for c in cur.description]
        return [dict(zip(cols, r)) for r in cur.fetchall()]


def query(statement: str, params: dict | None = None) -> list[dict]:
    with session() as conn:
        return rows(conn, statement, params)


def execute(statement: str, params: dict | None = None) -> None:
    with session() as conn:
        with conn.cursor() as cur:
            cur.execute(statement, params or {})


# ---------------------------------------------------------------------------
# Stale-tolerant cache
# ---------------------------------------------------------------------------


class _Cache:
    """TTL cache that prefers serving something old to making someone wait."""

    def __init__(self):
        self._values: dict[str, tuple[float, object]] = {}
        self._locks: dict[str, threading.Lock] = {}
        self._guard = threading.Lock()
        self._refreshing: set[str] = set()

    def _lock_for(self, key: str) -> threading.Lock:
        with self._guard:
            return self._locks.setdefault(key, threading.Lock())

    def get(self, key: str, ttl: int, loader, block_if_empty: bool = True):
        entry = self._values.get(key)
        fresh = entry is not None and (time.monotonic() - entry[0]) < ttl

        if fresh:
            return entry[1]

        if entry is None:
            if not block_if_empty:
                self._refresh_async(key, loader)
                return None
            # Nothing to serve, so this caller waits. The per-key lock means a
            # burst of first requests wakes the warehouse ONCE rather than once
            # each, which on a cold serverless warehouse is the difference
            # between ten seconds and ten seconds times the burst.
            with self._lock_for(key):
                entry = self._values.get(key)
                if entry is not None:
                    return entry[1]
                value = loader()
                self._values[key] = (time.monotonic(), value)
                return value

        self._refresh_async(key, loader)
        return entry[1]

    def _refresh_async(self, key: str, loader) -> None:
        with self._guard:
            if key in self._refreshing:
                return
            self._refreshing.add(key)

        def run():
            try:
                value = loader()
                self._values[key] = (time.monotonic(), value)
            except Exception:
                # A failed refresh must never take down a page that already has
                # a usable value. Log it and let the next request try again.
                log.exception("cache refresh failed: %s", key)
            finally:
                with self._guard:
                    self._refreshing.discard(key)

        threading.Thread(target=run, daemon=True).start()

    def invalidate(self, key: str) -> None:
        self._values.pop(key, None)

    def invalidate_prefix(self, prefix: str) -> None:
        for key in [k for k in self._values if k.startswith(prefix)]:
            self._values.pop(key, None)


CACHE = _Cache()


# ---------------------------------------------------------------------------
# The catalogue
# ---------------------------------------------------------------------------


def _load_catalogue() -> dict:
    with session() as conn:
        styles = rows(
            conn,
            f"""SELECT product_id, style_id, style_name, category, subcategory, colour,
                       season, list_price, current_price, discount_pct, on_hand,
                       units_sold, return_rate_pct, sizes_in_stock, sizes_all,
                       in_stock, is_new, popularity_rank
                FROM {CATALOG}.gold.style_catalog
                ORDER BY popularity_rank""",
        )
        skus = rows(
            conn,
            f"""SELECT sku, product_id, style_id, style_name, category, subcategory,
                       colour, size, season, list_price, current_price, discount_pct,
                       on_hand, units_sold, return_rate_pct
                FROM {CATALOG}.gold.product_catalog""",
        )
        # THE FIT NOTE, and it is the most interesting thing on a product page.
        #
        # Every retailer knows why its returns happen and almost none of them
        # tell you before you buy. This turns returns_analysis - a mart built for
        # merchandisers - into a sentence a shopper can act on: if two in five
        # returns in this category are for size, say so and sell a size up.
        #
        # It rides along on the catalogue load rather than being fetched per page
        # view, because it changes once a day and a product page must not query.
        fit = rows(
            conn,
            f"""SELECT category, reason, returned_units,
                       ROUND(returned_units / SUM(returned_units) OVER (PARTITION BY category) * 100, 0) AS share
                FROM {CATALOG}.gold.returns_analysis
                QUALIFY ROW_NUMBER() OVER (PARTITION BY category ORDER BY returned_units DESC) = 1""",
        )

    # The two size columns are ARRAY<STRING> in Delta. The connector hands them
    # back as a Python list over Arrow, but a fallback path can produce a
    # numpy array or a stringified list depending on the driver's mood, and the
    # failure mode is a filter that silently matches nothing. Normalise once,
    # here, rather than defending in every page that touches them.
    for row in styles:
        row["sizes_in_stock"] = _as_list(row.get("sizes_in_stock"))
        row["sizes_all"] = _as_list(row.get("sizes_all"))

    by_sku = {r["sku"]: r for r in skus}
    by_product: dict[str, list[dict]] = {}
    for r in skus:
        by_product.setdefault(r["product_id"], []).append(r)

    # Size order has to be decided once, here, or every page invents its own.
    order = {"OS": 0, "XS": 1, "S": 2, "M": 3, "L": 4, "XL": 5}
    for group in by_product.values():
        group.sort(key=lambda r: order.get(r["size"], _as_int(r["size"], 99)))

    by_style: dict[str, list[dict]] = {}
    for r in styles:
        by_style.setdefault(r["style_id"], []).append(r)

    return {
        "styles": styles,
        "styles_by_id": {r["product_id"]: r for r in styles},
        "colourways": by_style,
        "skus": by_sku,
        "sizes": by_product,
        "categories": sorted({r["category"] for r in styles}),
        "colours": sorted({r["colour"] for r in styles}),
        "fit": {r["category"]: r for r in fit},
        "loaded_at": time.time(),
    }


def _as_int(value, fallback: int) -> int:
    try:
        return int(value)
    except (TypeError, ValueError):
        return fallback


def _as_list(value) -> list:
    if value is None:
        return []
    if isinstance(value, list):
        return value
    if isinstance(value, str):
        cleaned = value.strip().strip("[]")
        return [part.strip().strip("\"'") for part in cleaned.split(",") if part.strip()]
    try:
        return list(value)
    except TypeError:
        return []


def catalogue() -> dict:
    return CACHE.get("catalogue", CATALOG_TTL, _load_catalogue)


def reserved_units() -> dict:
    """Units already spoken for by orders that have not been cancelled.

    NEVER blocks. On a cold process this returns nothing and every product looks
    fully in stock; a second or two later the background load lands and the
    numbers correct themselves. Making a shopper wait on a warehouse cold start
    so that a stock count can be two units more accurate is the wrong trade.
    """
    value = CACHE.get("reserved", RESERVED_TTL, _load_reserved, block_if_empty=False)
    return value or {}


def _load_reserved() -> dict:
    try:
        result = query(
            f"""SELECT l.sku AS sku, SUM(l.quantity) AS reserved
                FROM {CATALOG}.ops.order_lines l
                JOIN {CATALOG}.ops.orders o ON o.order_id = l.order_id
                WHERE o.status <> 'cancelled'
                GROUP BY l.sku"""
        )
    except Exception:
        # The order book does not exist until the first checkout. That is a
        # normal state, not an error worth a stack trace on every page.
        log.info("order book not readable yet; treating reservations as empty")
        return {}
    return {r["sku"]: int(r["reserved"] or 0) for r in result}


def available(sku: str) -> int:
    """On-hand from the last pipeline snapshot, less what has been ordered since.

    STATED PLAINLY because it is the kind of thing that silently becomes a lie:
    this is not a reservation system. Two shoppers can buy the last unit at the
    same time and both succeed. A real storefront holds stock in a transactional
    store at add-to-bag time; a lakehouse snapshot cannot do that and should not
    pretend to.
    """
    row = catalogue()["skus"].get(sku)
    if not row:
        return 0
    return max(0, int(row["on_hand"] or 0) - reserved_units().get(sku, 0))


# ---------------------------------------------------------------------------
# The order book
# ---------------------------------------------------------------------------

_OPS_READY = threading.Event()

ORDERS_DDL = f"""
CREATE TABLE IF NOT EXISTS {CATALOG}.ops.orders (
  order_id       STRING,
  placed_at      TIMESTAMP,
  updated_at     TIMESTAMP,
  customer_name  STRING,
  customer_email STRING,
  phone          STRING,
  address_line   STRING,
  city           STRING,
  postcode       STRING,
  item_count     BIGINT,
  subtotal       DOUBLE,
  delivery_fee   DOUBLE,
  total          DOUBLE,
  status         STRING,
  channel        STRING,
  note           STRING
)
"""

ORDER_LINES_DDL = f"""
CREATE TABLE IF NOT EXISTS {CATALOG}.ops.order_lines (
  order_id    STRING,
  line_no     BIGINT,
  sku         STRING,
  product_id  STRING,
  style_name  STRING,
  category    STRING,
  colour      STRING,
  size        STRING,
  quantity    BIGINT,
  unit_price  DOUBLE,
  list_price  DOUBLE,
  line_total  DOUBLE
)
"""


def ensure_ops_tables() -> None:
    """Create the order book if it is not there yet.

    WHY THIS IS NOT TERRAFORM, since the rest of the platform is. Creating a
    table needs running compute at apply time, and the only compute that can
    reach this catalog is defined in the same module that would need it - a
    circular dependency dressed up as infrastructure. The schema also belongs
    with the code that writes it: these columns change when checkout changes,
    not when the platform does.

    Idempotent, and guarded so it costs one round trip per process rather than
    one per order.
    """
    if _OPS_READY.is_set():
        return
    with session() as conn:
        with conn.cursor() as cur:
            cur.execute(ORDERS_DDL)
            cur.execute(ORDER_LINES_DDL)
    _OPS_READY.set()


def new_order_id() -> str:
    """Human-readable, roughly sortable, and not guessable in sequence.

    Sequential ids would let anyone who placed order 41 read order 40 by editing
    the URL, because the confirmation page is reachable by id. The random tail
    is what stops that being a data leak, and it costs nothing.
    """
    stamp = date.today().strftime("%y%m%d")
    tail = "".join(random.choices(string.ascii_uppercase + string.digits, k=5))
    return f"MRD-{stamp}-{tail}"


def place_order(customer: dict, lines: list[dict], totals: dict) -> str:
    """Write one order and its lines. Two commits, deliberately in this order.

    Lines first, header second. If the process dies between them, the result is
    orphaned lines nobody will ever query - annoying. The other order produces an
    order with no contents, which is a confirmed sale you cannot fulfil.

    A real system makes this one transaction. Delta gives you atomicity per
    table, not across two, and pretending otherwise is how people end up
    trusting a guarantee that was never there. Two tables plus a deliberate
    ordering is the honest version.
    """
    ensure_ops_tables()
    order_id = new_order_id()

    values, params = [], {"oid": order_id}
    for i, line in enumerate(lines):
        values.append(
            f"(:oid, :n{i}, :sku{i}, :pid{i}, :name{i}, :cat{i}, :col{i}, "
            f":size{i}, :qty{i}, :unit{i}, :list{i}, :total{i})"
        )
        params.update({
            f"n{i}": i + 1,
            f"sku{i}": line["sku"],
            f"pid{i}": line["product_id"],
            f"name{i}": line["style_name"],
            f"cat{i}": line["category"],
            f"col{i}": line["colour"],
            f"size{i}": line["size"],
            f"qty{i}": int(line["quantity"]),
            f"unit{i}": float(line["current_price"]),
            f"list{i}": float(line["list_price"]),
            f"total{i}": float(line["line_total"]),
        })

    with session() as conn:
        with conn.cursor() as cur:
            cur.execute(
                f"""INSERT INTO {CATALOG}.ops.order_lines
                    (order_id, line_no, sku, product_id, style_name, category,
                     colour, size, quantity, unit_price, list_price, line_total)
                    VALUES {", ".join(values)}""",
                params,
            )
            cur.execute(
                f"""INSERT INTO {CATALOG}.ops.orders
                    (order_id, placed_at, updated_at, customer_name, customer_email,
                     phone, address_line, city, postcode, item_count, subtotal,
                     delivery_fee, total, status, channel, note)
                    VALUES (:oid, current_timestamp(), current_timestamp(), :name,
                            :email, :phone, :address, :city, :postcode, :items,
                            :subtotal, :delivery, :total, 'placed', 'online', NULL)""",
                {
                    "oid": order_id,
                    "name": customer["name"],
                    "email": customer["email"],
                    "phone": customer.get("phone") or "",
                    "address": customer["address"],
                    "city": customer["city"],
                    "postcode": customer["postcode"],
                    "items": int(totals["items"]),
                    "subtotal": float(totals["subtotal"]),
                    "delivery": float(totals["delivery"]),
                    "total": float(totals["total"]),
                },
            )

    # The stock a shopper sees should move the moment they buy something.
    CACHE.invalidate("reserved")
    CACHE.invalidate("order_summary")
    CACHE.invalidate_prefix("orders:")
    return order_id


def get_order(order_id: str) -> dict | None:
    header = query(
        f"SELECT * FROM {CATALOG}.ops.orders WHERE order_id = :id",
        {"id": order_id},
    )
    if not header:
        return None
    lines = query(
        f"SELECT * FROM {CATALOG}.ops.order_lines WHERE order_id = :id ORDER BY line_no",
        {"id": order_id},
    )
    order = header[0]
    order["lines"] = lines
    return order


def orders_by_email(email: str) -> list[dict]:
    return query(
        f"""SELECT order_id, placed_at, status, item_count, total
            FROM {CATALOG}.ops.orders
            WHERE lower(customer_email) = lower(:email)
            ORDER BY placed_at DESC
            LIMIT 25""",
        {"email": email},
    )


def recent_orders(status: str | None = None, limit: int = 60) -> list[dict]:
    def load():
        try:
            if status:
                return query(
                    f"""SELECT order_id, placed_at, updated_at, customer_name, city,
                               item_count, total, status
                        FROM {CATALOG}.ops.orders
                        WHERE status = :status
                        ORDER BY placed_at DESC LIMIT {int(limit)}""",
                    {"status": status},
                )
            return query(
                f"""SELECT order_id, placed_at, updated_at, customer_name, city,
                           item_count, total, status
                    FROM {CATALOG}.ops.orders
                    ORDER BY placed_at DESC LIMIT {int(limit)}"""
            )
        except Exception:
            log.info("order book not readable yet")
            return []

    return CACHE.get(f"orders:{status or 'all'}", ORDERS_TTL, load) or []


def order_summary() -> list[dict]:
    def load():
        try:
            return query(
                f"""SELECT status, COUNT(*) AS orders, SUM(item_count) AS units,
                           ROUND(SUM(total), 0) AS value
                    FROM {CATALOG}.ops.orders
                    GROUP BY status"""
            )
        except Exception:
            return []

    return CACHE.get("order_summary", ORDERS_TTL, load) or []


def set_order_status(order_id: str, status: str, note: str | None = None) -> None:
    if status not in ORDER_STATUSES:
        raise ValueError(f"unknown status: {status}")
    execute(
        f"""UPDATE {CATALOG}.ops.orders
            SET status = :status,
                updated_at = current_timestamp(),
                note = COALESCE(:note, note)
            WHERE order_id = :id""",
        {"status": status, "note": note, "id": order_id},
    )
    CACHE.invalidate("order_summary")
    CACHE.invalidate_prefix("orders:")
    if status == "cancelled":
        CACHE.invalidate("reserved")


# ---------------------------------------------------------------------------
# Console analytics
# ---------------------------------------------------------------------------


def analytics(days: int) -> dict:
    """Everything the console's merchandising view needs, on one connection."""

    def load():
        window = f"""sale_date >= date_sub(
            (SELECT MAX(sale_date) FROM {CATALOG}.gold.daily_sales), {int(days)})"""
        with session() as conn:
            return {
                "kpis": rows(
                    conn,
                    f"""SELECT ROUND(SUM(net_revenue), 0) AS net_revenue,
                               ROUND(SUM(margin_amount) / NULLIF(SUM(net_revenue), 0) * 100, 1) AS margin_pct,
                               SUM(units_sold) AS units_sold,
                               ROUND(SUM(discount_amount) / NULLIF(SUM(gross_amount), 0) * 100, 1) AS discount_pct,
                               SUM(transactions) AS transactions
                        FROM {CATALOG}.gold.daily_sales WHERE {window}""",
                ),
                "trend": rows(
                    conn,
                    f"""SELECT sale_date,
                               ROUND(SUM(net_revenue), 0) AS net_revenue,
                               ROUND(SUM(margin_amount) / NULLIF(SUM(net_revenue), 0) * 100, 1) AS margin_pct
                        FROM {CATALOG}.gold.daily_sales WHERE {window}
                        GROUP BY sale_date ORDER BY sale_date""",
                ),
                "category": rows(
                    conn,
                    f"""SELECT category, ROUND(SUM(net_revenue), 0) AS net_revenue
                        FROM {CATALOG}.gold.daily_sales WHERE {window}
                        GROUP BY category ORDER BY net_revenue DESC""",
                ),
                "returns": rows(
                    conn,
                    f"""SELECT reason, SUM(returned_units) AS returned_units,
                               ROUND(AVG(avg_days_to_return), 1) AS avg_days
                        FROM {CATALOG}.gold.returns_analysis
                        GROUP BY reason ORDER BY returned_units DESC""",
                ),
                "inventory": rows(
                    conn,
                    f"""SELECT status, COUNT(*) AS lines, ROUND(SUM(stock_value), 0) AS stock_value
                        FROM {CATALOG}.gold.inventory_health GROUP BY status""",
                ),
                "top": rows(
                    conn,
                    f"""SELECT style_name, category, season, units_sold,
                               ROUND(net_revenue, 0) AS net_revenue, margin_amount,
                               avg_discount_pct, return_rate_pct
                        FROM {CATALOG}.gold.top_products
                        ORDER BY revenue_rank LIMIT 12""",
                ),
                "worst_size": rows(
                    conn,
                    f"""SELECT style_id FROM {CATALOG}.gold.size_curve
                        GROUP BY style_id ORDER BY MAX(ABS(imbalance)) DESC LIMIT 1""",
                ),
            }

    return CACHE.get(f"analytics:{days}", ANALYTICS_TTL, load)


def size_curve(style_id: str) -> list[dict]:
    return query(
        f"""SELECT size, demand_share, stock_share, signal
            FROM {CATALOG}.gold.size_curve
            WHERE style_id = :style
            ORDER BY CASE size WHEN 'XS' THEN 1 WHEN 'S' THEN 2 WHEN 'M' THEN 3
                               WHEN 'L' THEN 4 WHEN 'XL' THEN 5 ELSE 6 END""",
        {"style": style_id},
    )


def inventory_lines(status: str | None, limit: int = 200) -> list[dict]:
    def load():
        clause = "WHERE status = :status" if status else ""
        return query(
            f"""SELECT sku, style_name, category, colour, size, store_name, city,
                       on_hand, on_order, daily_sell_rate, days_of_cover, status,
                       stock_value
                FROM {CATALOG}.gold.inventory_health
                {clause}
                ORDER BY stock_value DESC
                LIMIT {int(limit)}""",
            {"status": status} if status else {},
        )

    return CACHE.get(f"inventory:{status or 'all'}", ANALYTICS_TTL, load) or []


def quality_report() -> dict:
    """Quarantine counts from silver. The console is the only reader of these.

    A data quality page nobody can reach is a data quality page nobody reads,
    which is why the console identity holds SELECT on silver and the storefront
    identity does not.
    """

    def load():
        out = {}
        with session() as conn:
            for stream in ("sales", "returns", "inventory"):
                try:
                    out[stream] = rows(
                        conn,
                        f"""SELECT rule, COUNT(*) AS failing FROM (
                                SELECT EXPLODE(_violations) AS rule
                                FROM {CATALOG}.silver.{stream}_quarantine
                            ) GROUP BY rule ORDER BY failing DESC""",
                    )
                except Exception:
                    # No quarantine table means nothing has ever failed a rule,
                    # which is the good outcome and not an error.
                    out[stream] = []
        return out

    return CACHE.get("quality", ANALYTICS_TTL, load) or {}
