"""MERIDIAN OPS — the console behind the shop.

The storefront creates demand. This is where somebody has to live with it:
orders arrive, get picked, shipped and occasionally cancelled, and the same
person wants to know whether the week is any good and which sizes are broken.

Two data paths, and the difference matters:

  gold.*   read-only marts, rebuilt by the pipeline. Cached for minutes,
           because a five-minute-old margin figure changes no decision.
  ops.*    the live order book, written by the shop and UPDATED here. Cached
           for seconds, because an order that has already been picked showing
           as new is exactly the failure an ops tool must not have.

This console holds SELECT on silver as well, which the storefront does not, so
the data quality page can show what the pipeline quarantined. Same platform,
deliberately different keys.
"""

import logging
import os
from urllib.parse import quote

from fastapi import APIRouter, FastAPI, Form, Request
from fastapi.responses import HTMLResponse, RedirectResponse

from . import charts, db
from .fmt import compact, count, e, pct, price, when
from .theme import CONSOLE_CSS, CONSOLE_JS

log = logging.getLogger("meridian.console")

BRAND = os.getenv("BRAND_NAME", "MERIDIAN")
SERVING = os.getenv("SERVING_COMPUTE", "a SQL warehouse")
router = APIRouter()

# Stock status carries MEANING, so it uses the fixed status palette and never a
# categorical slot. Never colour alone either - each one ships with a glyph,
# because two of these steps sit deliberately below a 3:1 contrast ratio.
STOCK_ROLE = {
    "stockout": ("--critical", "●"),
    "critical": ("--serious", "◐"),
    "low": ("--warning", "◑"),
    "healthy": ("--good", "○"),
    "overstock": ("--series-2", "●"),
    "dead": ("--dead", "◆"),
}
STOCK_ORDER = ["stockout", "critical", "low", "healthy", "overstock", "dead"]

ORDER_ROLE = {
    "placed": "--warning",
    "packed": "--series-1",
    "shipped": "--series-2",
    "delivered": "--good",
    "cancelled": "--critical",
}

PAGES = [
    ("/", "Overview"),
    ("/orders", "Order book"),
    ("/merchandising", "Merchandising"),
    ("/inventory", "Inventory"),
    ("/quality", "Data quality"),
]


# ---------------------------------------------------------------------------
# Chrome
# ---------------------------------------------------------------------------


def shell(title: str, head: str, body: str, active: str) -> HTMLResponse:
    nav = "".join(
        f'<a href="{path}" class="{"on" if path == active else ""}">{e(label)}</a>'
        for path, label in PAGES
    )
    return HTMLResponse(f"""<!doctype html>
<html lang="en">
<head>
<meta charset="utf-8">
<meta name="viewport" content="width=device-width,initial-scale=1">
<title>{e(title)} · {e(BRAND)} Ops</title>
<meta name="robots" content="noindex">
{CONSOLE_CSS}
</head>
<body>
<div class="shell">
  <aside>
    <div class="brand"><b>{e(BRAND)}</b><span>Operations</span></div>
    <nav>{nav}</nav>
    <div class="foot">
      Catalog <code>{e(db.CATALOG)}</code><br>
      Compute: {e(SERVING)}<br>
      Managed identity · no stored credentials
    </div>
  </aside>
  <main>
    {head}
    {body}
  </main>
</div>
<div id="tip" role="status" aria-live="polite"></div>
{CONSOLE_JS}
</body></html>""")


def head(title: str, subtitle: str, aside: str = "") -> str:
    return f"""<div class="head">
      <div><h1>{e(title)}</h1><p>{e(subtitle)}</p></div>
      {aside}
    </div>"""


def tile(label: str, value: str, sub: str, spark: str = "") -> str:
    return f"""<div class="tile">
      <div class="tile-label">{e(label)}</div>
      <div class="tile-value">{value}</div>
      <div class="tile-sub">{e(sub)}</div>
      {spark}
    </div>"""


def card(title: str, note: str, chart: str, table_html: str = "") -> str:
    """Every chart ships with a table view.

    Not optional. It is the accessible twin of the picture, and it is also how
    anyone reads an exact value off a chart without hovering pixel by pixel.
    """
    extra = f"<details><summary>Table view</summary>{table_html}</details>" if table_html else ""
    return f"""<section class="card">
      <header><h2>{e(title)}</h2><p>{e(note)}</p></header>
      {chart}
      {extra}
    </section>"""


def tag(label: str, role: str, glyph: str = "") -> str:
    dot = f'<i style="background:var({role})"></i>' if not glyph else f'<span style="color:var({role})">{glyph}</span>'
    return f'<span class="tag">{dot}{e(label)}</span>'


def order_tag(status: str) -> str:
    return tag(str(status).title(), ORDER_ROLE.get(status, "--muted"))


def stock_tag(status: str) -> str:
    role, glyph = STOCK_ROLE.get(status, ("--muted", "○"))
    return tag(str(status).title(), role, glyph)


# ---------------------------------------------------------------------------
# Overview
# ---------------------------------------------------------------------------


@router.get("/", response_class=HTMLResponse)
def overview(days: int = 28):
    days = days if days in (7, 14, 28) else 28
    data = db.analytics(days)
    summary = db.order_summary()
    orders = db.recent_orders(limit=12)

    k = data["kpis"][0] if data["kpis"] else {}
    trend = data["trend"]
    rev_points = [(str(r["sale_date"])[5:], float(r["net_revenue"] or 0)) for r in trend]

    by_status = {r["status"]: r for r in summary}
    live_orders = sum(int(r["orders"] or 0) for r in summary)
    live_value = sum(float(r["value"] or 0) for r in summary)
    open_orders = sum(
        int(by_status[s]["orders"] or 0) for s in ("placed", "packed", "shipped") if s in by_status
    )

    tiles = "".join([
        tile("Open orders", count(open_orders), "placed, packed or shipped"),
        tile("Orders taken", count(live_orders), f"{compact(live_value)} lifetime"),
        tile("Net revenue", compact(k.get("net_revenue") or 0), f"last {days} days, in-store and online",
             charts.sparkline([p[1] for p in rev_points])),
        tile("Margin", pct(k.get("margin_pct") or 0), "after cost of goods"),
        tile("Markdown", pct(k.get("discount_pct") or 0), "of gross, discounted"),
    ])

    if orders:
        rows = "".join(
            f"""<tr>
              <td class="name"><a href="/orders/{e(o['order_id'])}">{e(o['order_id'])}</a></td>
              <td>{e(o['customer_name'])}</td>
              <td class="dim">{e(o['city'])}</td>
              <td class="num">{count(o['item_count'])}</td>
              <td class="num">{price(o['total'])}</td>
              <td>{order_tag(o['status'])}</td>
              <td class="dim">{when(o['placed_at'])}</td>
            </tr>"""
            for o in orders
        )
        recent = f"""<div class="scroll"><table class="data">
          <thead><tr><th>Reference</th><th>Customer</th><th>City</th>
            <th class="num">Items</th><th class="num">Value</th><th>Status</th><th>Placed</th></tr></thead>
          <tbody>{rows}</tbody></table></div>"""
    else:
        recent = """<p class="empty">No orders yet. Place one on the storefront and it lands here
                    within a few seconds.</p>"""

    stock = {r["status"]: r for r in data["inventory"]}
    stock_rows = [(s, float(stock[s]["lines"])) for s in STOCK_ORDER if s in stock]

    body = f"""
<div class="tiles">{tiles}</div>
<div class="cards">
  <section class="card wide">
    <header><h2>Latest orders</h2><p>Written by the storefront to
      <code>{e(db.CATALOG)}.ops.orders</code>. Refreshed every few seconds.</p></header>
    {recent}
  </section>
  {card("Inventory health",
        "Dead stock is stock with no sales at all, which used to be reported as healthy.",
        charts.bar_chart(stock_rows, label="SKU-store lines by stock status",
                         colors=[STOCK_ROLE[s][0] for s, _ in stock_rows],
                         icons=[STOCK_ROLE[s][1] for s, _ in stock_rows]),
        charts.table(["Status", "Lines", "Stock value"],
                     [(s, count(stock[s]["lines"]), compact(stock[s]["stock_value"] or 0))
                      for s in STOCK_ORDER if s in stock],
                     unit_cols=(1, 2)))}
  {card("Revenue by category",
        "Nominal categories, one colour. Length carries the magnitude.",
        charts.bar_chart([(r["category"], float(r["net_revenue"] or 0)) for r in data["category"]],
                         unit="INR", label="Net revenue by category"),
        charts.table(["Category", "Net revenue"],
                     [(r["category"], compact(r["net_revenue"])) for r in data["category"]],
                     unit_cols=(1,)))}
</div>
"""
    ranges = '<div class="ranges">' + "".join(
        f'<a href="/?days={n}" class="{"on" if n == days else ""}">{n}d</a>' for n in (7, 14, 28)
    ) + "</div>"
    return shell("Overview", head("Overview", "Trading and the live order book, side by side.", ranges), body, "/")


# ---------------------------------------------------------------------------
# Order book
# ---------------------------------------------------------------------------


@router.get("/orders", response_class=HTMLResponse)
def order_book(status: str = "", note: str = ""):
    status = status if status in db.ORDER_STATUSES else ""
    orders = db.recent_orders(status or None, limit=100)
    summary = {r["status"]: r for r in db.order_summary()}

    filters = '<div class="filters">' + "".join(
        [f'<a href="/orders" class="{"on" if not status else ""}">All</a>']
        + [
            f'<a href="/orders?status={s}" class="{"on" if status == s else ""}">'
            f"{s.title()} ({int(summary.get(s, {}).get('orders') or 0)})</a>"
            for s in db.ORDER_STATUSES
        ]
    ) + "</div>"

    if orders:
        rows = "".join(
            f"""<tr>
              <td class="name"><a href="/orders/{e(o['order_id'])}">{e(o['order_id'])}</a></td>
              <td>{when(o['placed_at'])}</td>
              <td>{e(o['customer_name'])}</td>
              <td class="dim">{e(o['city'])}</td>
              <td class="num">{count(o['item_count'])}</td>
              <td class="num">{price(o['total'])}</td>
              <td>{order_tag(o['status'])}</td>
              <td>{_actions(o['order_id'], o['status'], compact_row=True)}</td>
            </tr>"""
            for o in orders
        )
        table = f"""<div class="scroll"><table class="data">
          <thead><tr><th>Reference</th><th>Placed</th><th>Customer</th><th>City</th>
            <th class="num">Items</th><th class="num">Value</th><th>Status</th><th></th></tr></thead>
          <tbody>{rows}</tbody></table></div>"""
    else:
        table = '<p class="empty">Nothing here. Place an order on the storefront.</p>'

    banner = f'<div class="card" style="margin-bottom:1rem"><b>{e(note)}</b></div>' if note else ""

    return shell(
        "Order book",
        head("Order book", "Live from ops.orders. Advancing a status writes an UPDATE to Delta."),
        banner + filters + f'<section class="card wide">{table}</section>',
        "/orders",
    )


def _actions(order_id: str, status: str, compact_row: bool = False) -> str:
    """Buttons that change state, as forms.

    POST, never a link. A GET that mutates gets fired by a link prefetcher, a
    crawler or the browser's own back-forward cache, and the first time an
    order ships itself because someone hovered a row is the last time anyone
    trusts the tool.
    """
    nxt = db.NEXT_STATUS.get(status)
    if not nxt:
        return "" if compact_row else '<p class="empty">This order is closed.</p>'

    advance = (
        f"""<form method="post" action="/orders/{e(order_id)}/status" class="inline">
              <input type="hidden" name="status" value="{e(nxt)}">
              <button class="act primary">Mark {e(nxt)}</button>
            </form>"""
        if nxt
        else ""
    )
    cancel = (
        f"""<form method="post" action="/orders/{e(order_id)}/status" class="inline">
              <input type="hidden" name="status" value="cancelled">
              <button class="act danger">Cancel</button>
            </form>"""
        if status in ("placed", "packed")
        else ""
    )
    return f'<div class="filters" style="margin:0;gap:.4rem">{advance}{cancel}</div>'


@router.get("/orders/{order_id}", response_class=HTMLResponse)
def order_detail(order_id: str):
    try:
        order = db.get_order(order_id)
    except Exception:
        log.exception("order read failed")
        order = None

    if not order:
        return shell(
            "Not found",
            head("Order not found", "No row in the order book with that reference."),
            '<p class="empty">Check the reference, or go back to the <a href="/orders">order book</a>.</p>',
            "/orders",
        )

    lines = "".join(
        f"""<tr>
          <td class="name">{e(l['style_name'])}</td>
          <td class="dim">{e(l['category'])}</td>
          <td>{e(l['colour'])}</td>
          <td>{e(l['size'])}</td>
          <td class="dim"><code>{e(l['sku'])}</code></td>
          <td class="num">{l['quantity']}</td>
          <td class="num">{price(l['unit_price'])}</td>
          <td class="num">{price(l['line_total'])}</td>
        </tr>"""
        for l in order["lines"]
    )

    body = f"""
<div class="cards">
  <section class="card wide">
    <header><h2>Lines</h2><p>{len(order['lines'])} lines · {count(order['item_count'])} units</p></header>
    <div class="scroll"><table class="data">
      <thead><tr><th>Style</th><th>Category</th><th>Colour</th><th>Size</th><th>SKU</th>
        <th class="num">Qty</th><th class="num">Each</th><th class="num">Total</th></tr></thead>
      <tbody>{lines}</tbody></table></div>
  </section>

  <section class="card">
    <header><h2>Fulfilment</h2><p>Status changes are UPDATEs against Delta, one commit each.</p></header>
    <dl class="kv">
      <dt>Status</dt><dd>{order_tag(order['status'])}</dd>
      <dt>Placed</dt><dd>{when(order['placed_at'])}</dd>
      <dt>Updated</dt><dd>{when(order['updated_at'])}</dd>
      <dt>Channel</dt><dd>{e(order['channel'])}</dd>
    </dl>
    <div style="margin-top:1.2rem">{_actions(order['order_id'], order['status'])}</div>
    <form method="post" action="/orders/{e(order['order_id'])}/status" style="margin-top:1rem">
      <input type="hidden" name="status" value="{e(order['status'])}">
      <input class="text" name="note" maxlength="200" style="width:100%"
             placeholder="Add a note (visible to ops only)" value="{e(order['note'] or '')}">
      <button class="act" style="margin-top:.6rem">Save note</button>
    </form>
  </section>

  <section class="card">
    <header><h2>Customer</h2><p>Collected at checkout. No payment details exist.</p></header>
    <dl class="kv">
      <dt>Name</dt><dd>{e(order['customer_name'])}</dd>
      <dt>Email</dt><dd>{e(order['customer_email'])}</dd>
      <dt>Phone</dt><dd>{e(order['phone'] or '—')}</dd>
      <dt>Address</dt><dd>{e(order['address_line'])}</dd>
      <dt>City</dt><dd>{e(order['city'])} {e(order['postcode'])}</dd>
    </dl>
    <dl class="kv" style="margin-top:1.2rem">
      <dt>Subtotal</dt><dd>{price(order['subtotal'])}</dd>
      <dt>Delivery</dt><dd>{price(order['delivery_fee'])}</dd>
      <dt>Total</dt><dd><b>{price(order['total'])}</b></dd>
    </dl>
  </section>
</div>
"""
    return shell(
        f"Order {order['order_id']}",
        head(order["order_id"], f"{order['customer_name']} · {when(order['placed_at'])}"),
        body,
        "/orders",
    )


@router.post("/orders/{order_id}/status")
def change_status(order_id: str, status: str = Form(...), note: str = Form("")):
    try:
        db.set_order_status(order_id, status, (note.strip() or None) if note else None)
        message = f"{order_id} is now {status}."
    except ValueError:
        message = "That status does not exist."
    except Exception:
        log.exception("status update failed")
        message = "The update did not go through. Try again in a moment."
    return RedirectResponse(f"/orders?note={quote(message)}", status_code=303)


# ---------------------------------------------------------------------------
# Merchandising
# ---------------------------------------------------------------------------


@router.get("/merchandising", response_class=HTMLResponse)
def merchandising(days: int = 28):
    days = days if days in (7, 14, 28) else 28
    data = db.analytics(days)
    trend = data["trend"]

    rev_points = [(str(r["sale_date"])[5:], float(r["net_revenue"] or 0)) for r in trend]
    margin_points = [(str(r["sale_date"])[5:], float(r["margin_pct"] or 0)) for r in trend]

    style_id = data["worst_size"][0]["style_id"] if data["worst_size"] else None
    curve = db.size_curve(style_id) if style_id else []
    size_groups = [(r["size"], [float(r["demand_share"] or 0), float(r["stock_share"] or 0)]) for r in curve]

    top_rows = "".join(
        f"""<tr>
          <td class="dim">{i}</td>
          <td class="name">{e(r['style_name'])}</td>
          <td class="dim">{e(r['category'])}</td>
          <td class="dim">{e(r['season'])}</td>
          <td class="num">{count(r['units_sold'])}</td>
          <td class="num">{compact(r['net_revenue'])}</td>
          <td class="num">{compact(r['margin_amount'])}</td>
          <td class="num">{pct(r['avg_discount_pct'])}</td>
          <td class="num">{pct(r['return_rate_pct'])}</td>
        </tr>"""
        for i, r in enumerate(data["top"], 1)
    )

    body = f"""
<div class="cards">
  {card("Daily net revenue", f"After returns. Last {days} days.",
        charts.line_chart(rev_points, unit="INR", label="Daily net revenue"),
        charts.table(["Date", "Net revenue", "Margin %"],
                     [(str(r["sale_date"]), compact(r["net_revenue"]), pct(r["margin_pct"]))
                      for r in trend], unit_cols=(1, 2)))}

  {card("Daily margin", "Revenue alone hides a day that hit target on 50% markdown.",
        charts.line_chart(margin_points, unit="%", label="Daily margin percent",
                          series_role="--series-2"),
        charts.table(["Date", "Margin %"],
                     [(str(r["sale_date"]), pct(r["margin_pct"])) for r in trend], unit_cols=(1,)))}

  {card("Returns by reason", "Net revenue is the only honest number, and this is what it nets off.",
        charts.bar_chart([(r["reason"], float(r["returned_units"] or 0)) for r in data["returns"]],
                         label="Returned units by reason"),
        charts.table(["Reason", "Units", "Avg days to return"],
                     [(r["reason"], count(r["returned_units"]), r["avg_days"]) for r in data["returns"]],
                     unit_cols=(1, 2)))}

  {card(f"Size curve — {style_id or 'n/a'}",
        "Selling out of M while XS sits on the shelf is invisible at style level.",
        '<div class="legend"><span><i style="background:var(--series-1)"></i>Demand share</span>'
        '<span><i style="background:var(--series-2)"></i>Stock share</span></div>'
        + charts.grouped_bars(size_groups, ["demand", "stock"], unit="%",
                              label="Demand versus stock share by size"),
        charts.table(["Size", "Demand %", "Stock %", "Signal"],
                     [(r["size"], pct(r["demand_share"]), pct(r["stock_share"]), r["signal"])
                      for r in curve], unit_cols=(1, 2)))}

  <section class="card wide">
    <header><h2>Top styles by revenue</h2>
      <p>Return rate is the column that changes decisions.</p></header>
    <div class="scroll"><table class="data">
      <thead><tr><th></th><th>Style</th><th>Category</th><th>Season</th>
        <th class="num">Units</th><th class="num">Net revenue</th><th class="num">Margin</th>
        <th class="num">Avg discount</th><th class="num">Return rate</th></tr></thead>
      <tbody>{top_rows}</tbody></table></div>
  </section>
</div>
"""
    ranges = '<div class="ranges">' + "".join(
        f'<a href="/merchandising?days={n}" class="{"on" if n == days else ""}">{n}d</a>'
        for n in (7, 14, 28)
    ) + "</div>"
    return shell(
        "Merchandising",
        head("Merchandising", "Read from the gold marts. Cached, because a five-minute-old margin changes nothing.", ranges),
        body,
        "/merchandising",
    )


# ---------------------------------------------------------------------------
# Inventory
# ---------------------------------------------------------------------------


@router.get("/inventory", response_class=HTMLResponse)
def inventory(status: str = ""):
    status = status if status in STOCK_ORDER else ""
    lines = db.inventory_lines(status or None)

    filters = '<div class="filters">' + "".join(
        [f'<a href="/inventory" class="{"on" if not status else ""}">All</a>']
        + [
            f'<a href="/inventory?status={s}" class="{"on" if status == s else ""}">{s.title()}</a>'
            for s in STOCK_ORDER
        ]
    ) + "</div>"

    rows = "".join(
        f"""<tr>
          <td class="dim"><code>{e(r['sku'])}</code></td>
          <td class="name">{e(r['style_name'])}</td>
          <td class="dim">{e(r['category'])}</td>
          <td>{e(r['colour'])}</td>
          <td>{e(r['size'])}</td>
          <td class="dim">{e(r['store_name'])}</td>
          <td class="num">{count(r['on_hand'])}</td>
          <td class="num">{count(r['on_order'])}</td>
          <td class="num">{r['daily_sell_rate']}</td>
          <td class="num">{r['days_of_cover'] if r['days_of_cover'] is not None else '—'}</td>
          <td>{stock_tag(r['status'])}</td>
          <td class="num">{compact(r['stock_value'])}</td>
        </tr>"""
        for r in lines
    )

    table = (
        f"""<div class="scroll"><table class="data">
          <thead><tr><th>SKU</th><th>Style</th><th>Category</th><th>Colour</th><th>Size</th>
            <th>Store</th><th class="num">On hand</th><th class="num">On order</th>
            <th class="num">Sell rate</th><th class="num">Days cover</th><th>Status</th>
            <th class="num">Value</th></tr></thead>
          <tbody>{rows}</tbody></table></div>"""
        if lines
        else '<p class="empty">Nothing matches that filter.</p>'
    )

    explain = """<section class="card" style="margin-bottom:1rem">
      <header><h2>Reading this</h2><p>Days of cover is on-hand divided by the daily sell rate
        over the last fortnight. Blank means nothing sold, which is the <b>dead</b> status —
        the state that used to be reported as healthy because every comparison against a null
        sell rate silently failed.</p></header>
    </section>"""

    return shell(
        "Inventory",
        head("Inventory", "Top 200 lines by stock value, from gold.inventory_health."),
        explain + filters + f'<section class="card wide">{table}</section>',
        "/inventory",
    )


# ---------------------------------------------------------------------------
# Data quality
# ---------------------------------------------------------------------------


@router.get("/quality", response_class=HTMLResponse)
def quality():
    report = db.quality_report()

    sections = ""
    for stream, findings in report.items():
        if findings:
            rows = "".join(
                f'<tr><td class="name">{e(r["rule"])}</td><td class="num">{count(r["failing"])}</td></tr>'
                for r in findings
            )
            table = f"""<table class="data"><thead><tr><th>Rule</th>
                        <th class="num">Rows failing</th></tr></thead><tbody>{rows}</tbody></table>"""
        else:
            table = '<p class="empty">Nothing quarantined. Every row passed every rule.</p>'
        sections += f"""<section class="card">
          <header><h2>{e(stream.title())}</h2>
            <p><code>{e(db.CATALOG)}.silver.{e(stream)}_quarantine</code></p></header>
          {table}
        </section>"""

    intro = """<section class="card wide" style="margin-bottom:1rem">
      <header><h2>Why rows end up here</h2>
      <p>Silver applies named business rules and keeps failing rows WITH the list of rules they
      broke, rather than dropping them. A row that parsed only partially — anything Auto Loader
      had to rescue in bronze — fails too, which is the promise bronze makes on silver's behalf.
      An empty table is the healthy state; a growing one is an upstream conversation.</p></header>
    </section>"""

    return shell(
        "Data quality",
        head("Data quality", "Quarantine counts by rule. This console is the only reader of silver."),
        intro + f'<div class="cards">{sections}</div>',
        "/quality",
    )


@router.get("/health")
def health():
    """Liveness only — deliberately does NOT touch Databricks. See the shop."""
    return {"status": "ok", "role": "console"}


def build() -> FastAPI:
    app = FastAPI(title=f"{BRAND} operations", docs_url=None, redoc_url=None)
    app.include_router(router)

    @app.exception_handler(Exception)
    async def warming(request: Request, exc: Exception):
        """One honest page for anything unhandled; the detail goes to the log.

        The console can afford to be more specific than the shop, because the
        only person who reaches it is the operator - so it names the two things
        that actually go wrong and what to do about each.
        """
        log.exception("unhandled request error: %s", request.url.path)
        response = shell(
            "Waiting on the warehouse",
            head("Not ready", "The query did not come back."),
            """<section class="card wide">
              <header><h2>Two things this usually is</h2></header>
              <p style="color:var(--text-secondary);line-height:1.9">
                <b>The warehouse is starting.</b> Serverless SQL stops when idle and takes a
                few seconds to come back. Reload.<br>
                <b>The gold layer does not exist yet.</b> Run the <code>fashion-medallion</code>
                job once, then reload.
              </p>
              <p style="margin-top:1.2rem"><a class="act" href="/">Try again</a></p>
            </section>""",
            "/",
        )
        # 503, not 500. The usual cause is compute that has not finished starting,
        # which is transient and worth retrying. A 500 tells a caller - and a
        # platform probe - to give up on something that will work in ten seconds.
        response.status_code = 503
        return response

    return app
