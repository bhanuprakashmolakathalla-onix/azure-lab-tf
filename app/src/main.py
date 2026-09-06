"""Merchandising dashboard over the fashion gold layer.

Deliberately server-rendered. No build step, no bundler, no client framework —
the page arrives complete, and every chart is SVG emitted by charts.py.

The interesting part is not the application. It is that nothing here holds a
credential:

    Container App  ->  user-assigned managed identity
                   ->  Entra token for the AzureDatabricks resource
                   ->  Databricks service principal (same application id)
                   ->  SQL warehouse
                   ->  fashion.gold.*

No connection string, no personal access token, nothing in an environment
variable that would matter if it leaked. The identity IS the credential, it is
issued at runtime, and it expires on its own.
"""

import logging
import os
from contextlib import contextmanager

from azure.identity import DefaultAzureCredential
from databricks import sql
from fastapi import FastAPI, HTTPException
from fastapi.responses import HTMLResponse

# uvicorn loads this as `src.main`, so `src` is the package and a bare
# `import charts` does not resolve. The fallback keeps `python src/main.py`
# working too, which is how you would debug it on the jumpbox.
try:
    from . import charts
except ImportError:  # pragma: no cover - direct-script execution
    import charts

logging.basicConfig(level=logging.INFO)
log = logging.getLogger("fashion")

# The AzureDatabricks first-party application. This constant has followed us
# through the whole build - it is the resource we ask Entra for a token for.
DATABRICKS_RESOURCE = "2ff814a6-3304-4ab8-85cb-cd0e6f879c1d"

SERVER_HOSTNAME = os.environ["DATABRICKS_SERVER_HOSTNAME"]
HTTP_PATH = os.environ["DATABRICKS_HTTP_PATH"]
CATALOG = os.getenv("CATALOG", "fashion")
BRAND = os.getenv("BRAND_NAME", "MERIDIAN")

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

app = FastAPI(title=f"{BRAND} merchandising", docs_url="/docs")


@contextmanager
def warehouse():
    """One short-lived connection per request.

    Pooling would be the obvious optimisation and is the wrong call here: a
    serverless SQL warehouse auto-stops when idle, so a pool of open connections
    is a pool of things keeping it awake and billing. Reconnecting costs
    milliseconds once the warehouse is running; keeping it running costs money
    continuously.
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


# ---------------------------------------------------------------------------
# Queries.
#
# All of them run on ONE connection per page render. Five round trips to a
# warehouse that has to wake up is five times the cold start; one connection
# amortises it. The gold layer is already aggregated, so every one of these
# returns tens of rows, not millions - the marts did the work.
# ---------------------------------------------------------------------------

SIZE_ORDER = "CASE size WHEN 'XS' THEN 1 WHEN 'S' THEN 2 WHEN 'M' THEN 3 WHEN 'L' THEN 4 WHEN 'XL' THEN 5 ELSE 6 END"


def queries(days: int) -> dict[str, str]:
    return {
        "kpis": f"""
            SELECT
              ROUND(SUM(net_revenue), 0)                                        AS net_revenue,
              ROUND(SUM(margin_amount) / NULLIF(SUM(net_revenue), 0) * 100, 1)  AS margin_pct,
              SUM(units_sold)                                                   AS units_sold,
              ROUND(SUM(discount_amount) / NULLIF(SUM(gross_amount), 0) * 100, 1) AS discount_pct,
              SUM(transactions)                                                 AS transactions
            FROM {CATALOG}.gold.daily_sales
            WHERE sale_date >= date_sub((SELECT MAX(sale_date) FROM {CATALOG}.gold.daily_sales), {days})
        """,
        "trend": f"""
            SELECT sale_date,
                   ROUND(SUM(net_revenue), 0) AS net_revenue,
                   ROUND(SUM(margin_amount) / NULLIF(SUM(net_revenue), 0) * 100, 1) AS margin_pct
            FROM {CATALOG}.gold.daily_sales
            WHERE sale_date >= date_sub((SELECT MAX(sale_date) FROM {CATALOG}.gold.daily_sales), {days})
            GROUP BY sale_date ORDER BY sale_date
        """,
        "category": f"""
            SELECT category, ROUND(SUM(net_revenue), 0) AS net_revenue
            FROM {CATALOG}.gold.daily_sales
            WHERE sale_date >= date_sub((SELECT MAX(sale_date) FROM {CATALOG}.gold.daily_sales), {days})
            GROUP BY category ORDER BY net_revenue DESC
        """,
        "top": f"""
            SELECT style_name, category, season, units_sold,
                   ROUND(net_revenue, 0) AS net_revenue,
                   margin_amount, avg_discount_pct, return_rate_pct
            FROM {CATALOG}.gold.top_products
            ORDER BY revenue_rank LIMIT 10
        """,
        "inventory": f"""
            SELECT status, COUNT(*) AS lines, ROUND(SUM(stock_value), 0) AS stock_value
            FROM {CATALOG}.gold.inventory_health
            GROUP BY status
        """,
        "returns": f"""
            SELECT reason, SUM(returned_units) AS returned_units,
                   ROUND(AVG(avg_days_to_return), 1) AS avg_days
            FROM {CATALOG}.gold.returns_analysis
            GROUP BY reason ORDER BY returned_units DESC
        """,
        # The single most under-stocked style: where the size curve is most
        # wrong. This is the chart a merchandiser would actually act on.
        "size_style": f"""
            SELECT style_id FROM {CATALOG}.gold.size_curve
            GROUP BY style_id ORDER BY MAX(ABS(imbalance)) DESC LIMIT 1
        """,
    }


def fetch(conn, query: str) -> list[dict]:
    with conn.cursor() as cur:
        cur.execute(query)
        cols = [c[0] for c in cur.description]
        return [dict(zip(cols, r)) for r in cur.fetchall()]


def load(days: int) -> dict:
    q = queries(days)
    with warehouse() as conn:
        data = {k: fetch(conn, v) for k, v in q.items()}

        style = data["size_style"][0]["style_id"] if data["size_style"] else None
        data["size_curve"] = (
            fetch(
                conn,
                f"""SELECT size, demand_share, stock_share, signal
                    FROM {CATALOG}.gold.size_curve
                    WHERE style_id = '{style}' ORDER BY {SIZE_ORDER}""",
            )
            if style
            else []
        )
        data["size_style_id"] = style
    return data


@app.get("/health")
def health():
    """Liveness only - deliberately does NOT touch Databricks.

    A health check that queries the warehouse would wake it on every probe, and
    the platform probes constantly. That is a genuinely expensive mistake: the
    thing meant to tell you the app is alive ends up preventing the warehouse
    from ever sleeping.
    """
    return {"status": "ok"}


@app.get("/api/summary")
def api_summary(days: int = 28):
    try:
        return load(int(days))
    except Exception as exc:  # noqa: BLE001
        log.exception("query failed")
        # 503 rather than 500: the usual cause is a warehouse still starting,
        # which is transient and worth retrying. A 500 tells a caller to give up
        # on something that will work in ten seconds.
        raise HTTPException(status_code=503, detail=str(exc)) from exc


# ---------------------------------------------------------------------------
# Rendering
# ---------------------------------------------------------------------------

# Status roles carry MEANING (stockout is bad), so they use the fixed status
# palette, never a categorical slot. And never colour alone - each one ships
# with an icon and a label, because the light/dark contrast of two of these
# steps is deliberately below 3:1.
STATUS_ROLE = {
    "stockout": ("--critical", "●"),
    "critical": ("--serious", "◐"),
    "low": ("--warning", "◑"),
    "healthy": ("--good", "○"),
    "overstock": ("--series-2", "●"),
}
STATUS_ORDER = ["stockout", "critical", "low", "healthy", "overstock"]


def _tile(label, value, sub, spark=""):
    return f"""<div class="tile">
      <div class="tile-label">{label}</div>
      <div class="tile-value">{value}</div>
      <div class="tile-sub">{sub}</div>
      {spark}
    </div>"""


def _card(title, note, chart, table_html):
    """Every chart ships with a table view. Not optional - it is the WCAG-clean
    twin, and it is also how anyone reads an exact value off a chart."""
    return f"""<section class="card">
      <header><h2>{title}</h2><p>{note}</p></header>
      {chart}
      <details><summary>Table view</summary>{table_html}</details>
    </section>"""


@app.get("/", response_class=HTMLResponse)
def index(days: int = 28):
    try:
        d = load(int(days))
    except Exception as exc:  # noqa: BLE001
        log.exception("render failed")
        return HTMLResponse(WAITING.format(brand=BRAND, detail=str(exc)[:400], css=CSS), status_code=503)

    k = d["kpis"][0] if d["kpis"] else {}
    trend = d["trend"]

    rev_points = [(str(r["sale_date"])[5:], float(r["net_revenue"] or 0)) for r in trend]
    margin_points = [(str(r["sale_date"])[5:], float(r["margin_pct"] or 0)) for r in trend]

    # --- KPI tiles ---------------------------------------------------------
    # A stat tile, not a one-bar bar chart. When the story is a single number,
    # the number IS the chart.
    tiles = "".join([
        _tile("Net revenue", charts.fmt(float(k.get("net_revenue") or 0)), f"last {days} days",
              charts.sparkline([p[1] for p in rev_points])),
        _tile("Margin", f"{k.get('margin_pct') or 0}%", "after cost of goods",
              charts.sparkline([p[1] for p in margin_points], role="--series-2")),
        _tile("Units sold", f"{int(k.get('units_sold') or 0):,}", f"{int(k.get('transactions') or 0):,} transactions"),
        _tile("Markdown", f"{k.get('discount_pct') or 0}%", "of gross, discounted"),
    ])

    # --- revenue and margin as TWO charts, never one ------------------------
    # Revenue is in rupees, margin is a percentage. Putting them on one plot
    # with two y-axes invents a correlation that is not in the data - the
    # single most common charting mistake there is.
    rev_chart = _card(
        "Daily net revenue",
        f"After returns. {days} days.",
        charts.line_chart(rev_points, unit="INR", label="Daily net revenue"),
        charts.table(["Date", "Net revenue", "Margin %"],
                     [(str(r["sale_date"]), f"{float(r['net_revenue'] or 0):,.0f}", f"{r['margin_pct']}%") for r in trend],
                     unit_cols=(1, 2)),
    )

    margin_chart = _card(
        "Daily margin",
        "Revenue alone hides a day that hit target on 50% markdown.",
        charts.line_chart(margin_points, unit="%", label="Daily margin percent", series_role="--series-2"),
        charts.table(["Date", "Margin %"], [(str(r["sale_date"]), f"{r['margin_pct']}%") for r in trend], unit_cols=(1,)),
    )

    # --- category: ONE colour for every bar --------------------------------
    # Categories are nominal - they have no order - so a darker-where-bigger
    # ramp would double-encode bar length as hue and burn the only free channel
    # on information the chart already shows.
    cats = [(r["category"], float(r["net_revenue"] or 0)) for r in d["category"]]
    cat_chart = _card(
        "Revenue by category",
        "Nominal categories, one colour. Length carries the magnitude.",
        charts.bar_chart(cats, unit="INR", label="Net revenue by category"),
        charts.table(["Category", "Net revenue"], [(c, f"{v:,.0f}") for c, v in cats], unit_cols=(1,)),
    )

    # --- returns -----------------------------------------------------------
    rets = [(r["reason"], float(r["returned_units"] or 0)) for r in d["returns"]]
    ret_chart = _card(
        "Returns by reason",
        "Net revenue is the only honest number, and this is what it nets off.",
        charts.bar_chart(rets, label="Returned units by reason"),
        charts.table(["Reason", "Units returned", "Avg days to return"],
                     [(r["reason"], f"{int(r['returned_units'] or 0):,}", r["avg_days"]) for r in d["returns"]],
                     unit_cols=(1, 2)),
    )

    # --- inventory status: STATUS palette, with icons ----------------------
    inv = {r["status"]: r for r in d["inventory"]}
    inv_rows = [(s, float(inv[s]["lines"])) for s in STATUS_ORDER if s in inv]
    inv_chart = _card(
        "Inventory health",
        "Status colours, never reused for a series. Icon and label carry the meaning too.",
        charts.bar_chart(
            inv_rows,
            label="SKU-store lines by stock status",
            colors=[STATUS_ROLE[s][0] for s, _ in inv_rows],
            icons=[STATUS_ROLE[s][1] for s, _ in inv_rows],
        ),
        charts.table(["Status", "SKU-store lines", "Stock value"],
                     [(s, f"{int(inv[s]['lines']):,}", f"{float(inv[s]['stock_value'] or 0):,.0f}")
                      for s in STATUS_ORDER if s in inv],
                     unit_cols=(1, 2)),
    )

    # --- size curve: two series, so a legend is mandatory -------------------
    sc = d["size_curve"]
    size_groups = [(r["size"], [float(r["demand_share"] or 0), float(r["stock_share"] or 0)]) for r in sc]
    size_chart = _card(
        f"Size curve — {d.get('size_style_id') or 'n/a'}",
        "Selling out of M while XS sits on the shelf is invisible at style level.",
        f"""<div class="legend">
              <span><i style="background:var(--series-1)"></i>Demand share</span>
              <span><i style="background:var(--series-2)"></i>Stock share</span>
            </div>"""
        + charts.grouped_bars(size_groups, ["demand", "stock"], unit="%", label="Demand vs stock share by size"),
        charts.table(["Size", "Demand %", "Stock %", "Signal"],
                     [(r["size"], f"{r['demand_share']}%", f"{r['stock_share']}%", r["signal"]) for r in sc],
                     unit_cols=(1, 2)),
    )

    top_rows = "".join(
        f"""<tr><td class="rank">{i}</td><td class="name">{r['style_name']}</td>
        <td class="dim">{r['category']}</td><td class="dim">{r['season']}</td>
        <td class="num">{int(r['units_sold']):,}</td>
        <td class="num">{float(r['net_revenue'] or 0):,.0f}</td>
        <td class="num">{r['avg_discount_pct']}%</td>
        <td class="num">{r['return_rate_pct']}%</td></tr>"""
        for i, r in enumerate(d["top"], 1)
    )

    return HTMLResponse(f"""<main>
  <header class="masthead">
    <div class="brand">{BRAND}<span>merchandising</span></div>
    <nav class="ranges">
      {''.join(f'<a href="/?days={n}" class="{"on" if n == days else ""}">{n}d</a>' for n in (7, 14, 28))}
    </nav>
  </header>

  <div class="tiles">{tiles}</div>

  <div class="grid">
    {rev_chart}
    {margin_chart}
    {cat_chart}
    {ret_chart}
    {size_chart}
    {inv_chart}
  </div>

  <section class="card wide">
    <header><h2>Top styles by revenue</h2><p>Return rate is the column that changes decisions.</p></header>
    <div class="scroll">
      <table class="data">
        <thead><tr><th></th><th>Style</th><th>Category</th><th>Season</th>
        <th class="num">Units</th><th class="num">Net revenue</th>
        <th class="num">Avg discount</th><th class="num">Return rate</th></tr></thead>
        <tbody>{top_rows}</tbody>
      </table>
    </div>
  </section>

  <footer>
    <code>{CATALOG}.gold</code> via managed identity &middot; no credentials in this container
    &middot; private endpoint only
  </footer>
</main>
<div id="tip" role="status" aria-live="polite"></div>
{CSS}{JS}""")


CSS = """<style>
:root {
  color-scheme: dark;
  --page:#0d0d0d; --surface-1:#1a1a19; --surface-2:#222220;
  --text-primary:#ffffff; --text-secondary:#c3c2b7; --muted:#898781;
  --grid:#2c2c2a; --axis:#383835; --hairline:rgba(255,255,255,.10);
  --series-1:#3987e5; --series-2:#d95926;
  --good:#0ca30c; --warning:#fab219; --serious:#ec835a; --critical:#d03b3b;
}
* { box-sizing:border-box; }
body { margin:0; background:var(--page); color:var(--text-primary);
       font:14px/1.55 system-ui,-apple-system,"Segoe UI",sans-serif;
       -webkit-font-smoothing:antialiased; }
main { max-width:1320px; margin:0 auto; padding:2.5rem 1.5rem 4rem; }

.masthead { display:flex; justify-content:space-between; align-items:baseline;
            padding-bottom:1.25rem; border-bottom:1px solid var(--hairline); }
.brand { font-size:1.35rem; font-weight:650; letter-spacing:.14em; }
.brand span { display:block; font-size:.68rem; font-weight:400; letter-spacing:.3em;
              color:var(--muted); text-transform:uppercase; margin-top:.3rem; }
.ranges { display:flex; gap:.25rem; }
.ranges a { color:var(--text-secondary); text-decoration:none; padding:.3rem .7rem;
            border-radius:999px; font-size:.82rem; border:1px solid transparent; }
.ranges a:hover { background:var(--surface-2); }
.ranges a.on { background:var(--surface-2); border-color:var(--hairline); color:var(--text-primary); }

.tiles { display:grid; grid-template-columns:repeat(auto-fit,minmax(190px,1fr));
         gap:1px; background:var(--hairline); border:1px solid var(--hairline);
         margin:1.75rem 0; border-radius:10px; overflow:hidden; }
.tile { background:var(--surface-1); padding:1.15rem 1.25rem 1rem; }
.tile-label { font-size:.7rem; letter-spacing:.12em; text-transform:uppercase; color:var(--muted); }
/* Proportional figures, deliberately. tabular-nums makes a large standalone
   number look loose - it belongs in columns that align vertically. */
.tile-value { font-size:2rem; font-weight:600; margin:.35rem 0 .1rem; letter-spacing:-.02em; }
.tile-sub { font-size:.78rem; color:var(--text-secondary); }
.spark { display:block; margin-top:.6rem; opacity:.85; }

.grid { display:grid; grid-template-columns:repeat(auto-fit,minmax(430px,1fr)); gap:1rem; }
.card { background:var(--surface-1); border:1px solid var(--hairline);
        border-radius:10px; padding:1.25rem 1.35rem 1rem; }
.card.wide { margin-top:1rem; }
.card header { margin-bottom:1rem; }
.card h2 { font-size:.95rem; font-weight:600; margin:0; letter-spacing:.01em; }
.card header p { margin:.25rem 0 0; font-size:.8rem; color:var(--muted); }

.chart { width:100%; height:auto; display:block; overflow:visible; }
.grid line.grid, line.grid { stroke:var(--grid); stroke-width:1; }
text.tick { fill:var(--muted); font-size:10px; font-variant-numeric:tabular-nums; }
text.endlabel { fill:var(--text-primary); font-size:11px; font-weight:600; }
text.barlabel { fill:var(--text-secondary); font-size:11px; }
text.barvalue { fill:var(--text-primary); font-size:11px; font-variant-numeric:tabular-nums; }
.hit { fill:transparent; cursor:crosshair; }
.barrow:hover .bar, .bar:hover { filter:brightness(1.15); }

.legend { display:flex; gap:1.1rem; margin-bottom:.5rem; font-size:.78rem; color:var(--text-secondary); }
.legend i { display:inline-block; width:9px; height:9px; border-radius:2px; margin-right:.4rem; }

details { margin-top:.85rem; border-top:1px solid var(--hairline); padding-top:.6rem; }
summary { cursor:pointer; font-size:.78rem; color:var(--muted); list-style:none; }
summary::-webkit-details-marker { display:none; }
summary::before { content:"\\25B8  "; }
details[open] summary::before { content:"\\25BE  "; }

.scroll { overflow-x:auto; }
table.data { border-collapse:collapse; width:100%; margin-top:.7rem; font-size:.82rem; }
table.data th { text-align:left; font-weight:600; color:var(--muted); font-size:.72rem;
                text-transform:uppercase; letter-spacing:.08em; padding:.4rem .6rem;
                border-bottom:1px solid var(--hairline); white-space:nowrap; }
table.data td { padding:.42rem .6rem; border-bottom:1px solid var(--grid); color:var(--text-secondary); }
table.data td.num, table.data th.num { text-align:right; font-variant-numeric:tabular-nums; }
table.data td.name { color:var(--text-primary); }
table.data td.dim { color:var(--muted); }
table.data td.rank { color:var(--muted); width:1.5rem; font-variant-numeric:tabular-nums; }
.empty { color:var(--muted); font-size:.85rem; padding:2rem 0; text-align:center; }

footer { margin-top:2.5rem; padding-top:1.25rem; border-top:1px solid var(--hairline);
         color:var(--muted); font-size:.78rem; }
code { background:var(--surface-2); padding:.12em .4em; border-radius:3px; color:var(--text-secondary); }

#tip { position:fixed; pointer-events:none; opacity:0; transition:opacity .1s;
       background:var(--surface-2); border:1px solid var(--hairline); border-radius:6px;
       padding:.4rem .6rem; font-size:.78rem; z-index:50; white-space:nowrap;
       box-shadow:0 6px 20px rgba(0,0,0,.5); }
#tip b { display:block; color:var(--text-primary); font-variant-numeric:tabular-nums; }
#tip span { color:var(--muted); }

@media (max-width:640px) {
  .grid { grid-template-columns:1fr; }
  main { padding:1.5rem 1rem 3rem; }
}
</style>"""

# Hover is not decoration. An HTML/SVG chart IS interactive, and a value that is
# only reachable by hovering would fail accessibility - which is why every chart
# above also has a table view. This layer enhances; it never gates.
JS = """<script>
(function () {
  var tip = document.getElementById('tip');
  document.addEventListener('mouseover', function (e) {
    var t = e.target.closest('[data-label]');
    if (!t) return;
    tip.innerHTML = '<span>' + t.dataset.label + '</span><b>' + t.dataset.value + '</b>';
    tip.style.opacity = 1;
  });
  document.addEventListener('mousemove', function (e) {
    if (tip.style.opacity !== '1') return;
    var x = e.clientX + 14, y = e.clientY + 14;
    if (x + tip.offsetWidth > innerWidth - 8) x = e.clientX - tip.offsetWidth - 14;
    tip.style.left = x + 'px'; tip.style.top = y + 'px';
  });
  document.addEventListener('mouseout', function (e) {
    if (e.target.closest('[data-label]')) tip.style.opacity = 0;
  });
})();
</script>"""

WAITING = """<main class="waiting">
  <div class="brand">{brand}<span>merchandising</span></div>
  <h1>Warehouse starting</h1>
  <p>A serverless SQL warehouse takes a few seconds to wake. This page will work on reload.</p>
  <pre>{detail}</pre>
</main>
<style>
  .waiting {{ max-width:44rem; margin:6rem auto; padding:0 1.5rem; }}
  .waiting h1 {{ font-size:1.2rem; font-weight:600; margin:2rem 0 .5rem; }}
  .waiting p {{ color:var(--text-secondary); }}
  .waiting pre {{ background:var(--surface-1); border:1px solid var(--hairline);
                 border-radius:8px; padding:1rem; overflow-x:auto; font-size:.75rem;
                 color:var(--muted); white-space:pre-wrap; }}
</style>
{css}"""
