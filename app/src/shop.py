"""MERIDIAN — the storefront.

Server-rendered HTML. No bundler, no client framework, no build step: the page
arrives complete and the only JavaScript is the handful of lines that make size
selection feel instant. Every product, price, size and stock figure on this site
is a real number out of the lakehouse - the catalogue is generated, but nothing
between the generator and this page is faked.

WHAT IT IS NOT: there is no payment. Checkout collects an address and writes a
real order to `fashion.ops.orders`, which the operations console then works
through. That is the whole point of the pair - one site creates the demand, the
other one has to live with it.
"""

import logging
import os
from urllib.parse import quote

from fastapi import APIRouter, FastAPI, Form, Request
from fastapi.responses import HTMLResponse, RedirectResponse

from . import cart, db, imagery
from .fmt import count, day, e, price, rupees, when
from .theme import SHOP_CSS, SHOP_JS

log = logging.getLogger("meridian.shop")

BRAND = os.getenv("BRAND_NAME", "MERIDIAN")
router = APIRouter()

SORTS = {
    "featured": "Featured",
    "new": "New in",
    "price-low": "Price: low to high",
    "price-high": "Price: high to low",
    "discount": "Biggest reductions",
}

TRACK_STEPS = ["placed", "packed", "shipped", "delivered"]


# ---------------------------------------------------------------------------
# Chrome
# ---------------------------------------------------------------------------


def _nav(active: str, categories: list[str]) -> str:
    links = "".join(
        f'<a href="/shop?category={quote(c)}" class="{"on" if active == c else ""}">{e(c)}</a>'
        for c in categories
    )
    sale = ' class="on"' if active == "sale" else ""
    return f'{links}<a href="/shop?sale=1"{sale}>Sale</a>'


def shell(title: str, body: str, bag_count: int, active: str = "", toast: str = "") -> HTMLResponse:
    cat = db.catalogue()
    badge = f'<span class="bag-count">{bag_count}</span>' if bag_count else ""
    return HTMLResponse(f"""<!doctype html>
<html lang="en">
<head>
<meta charset="utf-8">
<meta name="viewport" content="width=device-width,initial-scale=1">
<title>{e(title)} · {e(BRAND)}</title>
<meta name="description" content="{e(BRAND)} — ready-to-wear, shipped from store.">
{SHOP_CSS}
</head>
<body>
<div class="top">Free delivery over ₹{rupees(cart.FREE_DELIVERY_OVER)} · 30-day returns · Shipped from store</div>
<header class="site">
  <div class="wrap bar">
    <a href="/" class="wordmark">{e(BRAND)}</a>
    <nav class="main">{_nav(active, cat["categories"])}</nav>
    <div class="tools">
      <a href="/orders">Orders</a>
      <a href="/bag" class="bag-link">Bag {badge}</a>
    </div>
  </div>
</header>
{body}
<footer class="site">
  <div class="wrap">
    <div class="cols">
      <div>
        <div class="wordmark">{e(BRAND)}</div>
        <p style="max-width:34ch;margin-top:1rem;font-size:.86rem;line-height:1.8">
          Ready-to-wear, made in limited runs and shipped from the store nearest you.
        </p>
      </div>
      <div><h3>Shop</h3><ul>
        {"".join(f'<li><a href="/shop?category={quote(c)}">{e(c)}</a></li>' for c in cat["categories"])}
      </ul></div>
      <div><h3>Help</h3><ul>
        <li><a href="/orders">Track an order</a></li>
        <li><a href="/bag">Your bag</a></li>
        <li><a href="/shop?sale=1">Sale</a></li>
      </ul></div>
      <div><h3>Behind this</h3><ul>
        <li>Azure Databricks lakehouse</li>
        <li>Prices and stock from <code>gold</code></li>
        <li>Orders written to <code>ops</code></li>
        <li>No stored credentials</li>
      </ul></div>
    </div>
    <div class="fine">
      <span>Demonstration storefront. Real data, real orders, no payment is taken.</span>
      <span>Catalogue read from <code>{e(db.CATALOG)}.gold</code> over a private endpoint.</span>
    </div>
  </div>
</footer>
<div id="toast" data-message="{e(toast)}"></div>
{SHOP_JS}
</body></html>""")


# ---------------------------------------------------------------------------
# Components
# ---------------------------------------------------------------------------


def _price_block(row: dict) -> str:
    now = float(row["current_price"] or 0)
    was = float(row["list_price"] or 0)
    if was > now + 1:
        off = round((was - now) / was * 100)
        return (
            f'<span class="now">{price(now)}</span>'
            f'<span class="was">{price(was)}</span>'
            f'<span class="off">−{off}%</span>'
        )
    return f'<span class="now">{price(now)}</span>'


def card(row: dict, colourways: list[dict] | None = None) -> str:
    flags = []
    if not row.get("in_stock"):
        flags.append('<span class="flag gone">Sold out</span>')
    elif row.get("is_new"):
        flags.append('<span class="flag new">New</span>')
    if float(row["list_price"] or 0) > float(row["current_price"] or 0) + 1:
        off = round((float(row["list_price"]) - float(row["current_price"])) / float(row["list_price"]) * 100)
        flags.append(f'<span class="flag sale">−{off}%</span>')

    swatches = ""
    if colourways and len(colourways) > 1:
        swatches = '<div class="swatches">' + "".join(
            imagery.swatch(c["colour"], c["product_id"] == row["product_id"]) for c in colourways[:5]
        ) + "</div>"

    return f"""<a class="card" href="/product/{e(row['product_id'])}">
      <div class="frame">
        {imagery.product_image(row)}
        <div class="flags">{"".join(flags)}</div>
      </div>
      <div class="meta">
        <div class="name">{e(row['style_name'])}</div>
        <div class="sub">{e(row['colour'])} · {e(row['subcategory'])}</div>
        <div class="price">{_price_block(row)}</div>
        {swatches}
      </div>
    </a>"""


def grid(rows: list[dict], cat: dict) -> str:
    if not rows:
        return """<div class="empty-state"><h2>Nothing here yet</h2>
                  <p>Try clearing a filter, or browse everything.</p>
                  <p style="margin-top:1.5rem"><a class="btn ghost" href="/shop">View all</a></p></div>"""
    return '<div class="grid">' + "".join(
        card(r, cat["colourways"].get(r["style_id"])) for r in rows
    ) + "</div>"


def _bag_items(request: Request) -> list[dict]:
    return cart.decode(request.cookies.get(cart.COOKIE))


def _bag_count(items: list[dict]) -> int:
    return sum(i["qty"] for i in items)


# ---------------------------------------------------------------------------
# Home
# ---------------------------------------------------------------------------


@router.get("/", response_class=HTMLResponse)
def home(request: Request, added: str = ""):
    cat = db.catalogue()
    styles = cat["styles"]

    in_stock = [s for s in styles if s["in_stock"]]
    hero_art = "".join(imagery.product_image(s) for s in in_stock[:3])
    new_in = [s for s in styles if s["is_new"] and s["in_stock"]][:8]
    trending = in_stock[:8]
    reduced = sorted(
        [s for s in in_stock if float(s["list_price"] or 0) > float(s["current_price"] or 0) + 1],
        key=lambda s: float(s["list_price"]) - float(s["current_price"]),
        reverse=True,
    )[:4]

    tiles = "".join(
        f"""<a class="card" href="/shop?category={quote(c)}">
              <div class="frame">{imagery.product_image(next(s for s in styles if s['category'] == c))}</div>
              <div class="meta"><div class="name">{e(c)}</div>
              <div class="sub">{sum(1 for s in styles if s['category'] == c)} styles</div></div>
            </a>"""
        for c in cat["categories"]
    )

    body = f"""
<section class="hero">
  <div class="wrap">
    <div>
      <div class="eyebrow">Autumn Winter 25 · Spring Summer 26</div>
      <h1>Clothes that earn their place in the wardrobe.</h1>
      <p>Limited runs, honest markdowns, and a size guide built from what actually
         came back. Shipped from the store nearest you, usually within two days.</p>
      <a class="btn" href="/shop">Shop the collection</a>
      <a class="btn ghost" href="/shop?sale=1" style="margin-left:.6rem">View sale</a>
    </div>
    <div class="hero-art">{hero_art}</div>
  </div>
</section>

<section class="band">
  <div class="wrap">
    <div class="section-head">
      <div><div class="eyebrow">Just landed</div><h2>New in</h2></div>
      <a href="/shop?sort=new">See everything new</a>
    </div>
    {grid(new_in, cat)}
  </div>
</section>

<section class="band tight" style="background:var(--sunk);border-block:1px solid var(--rule)">
  <div class="wrap">
    <div class="section-head"><div><h2>Shop by category</h2></div></div>
    {'<div class="grid">' + tiles + '</div>'}
  </div>
</section>

<section class="band">
  <div class="wrap">
    <div class="section-head">
      <div><div class="eyebrow">Selling fastest</div><h2>Trending now</h2></div>
      <a href="/shop">Shop all</a>
    </div>
    {grid(trending, cat)}
  </div>
</section>

{'' if not reduced else f'''
<section class="band tight">
  <div class="wrap">
    <div class="section-head">
      <div><div class="eyebrow">End of season</div><h2>Biggest reductions</h2></div>
      <a href="/shop?sale=1">All sale</a>
    </div>
    {grid(reduced, cat)}
  </div>
</section>'''}
"""
    items = _bag_items(request)
    return shell("Ready-to-wear", body, _bag_count(items), toast=_toast_for(added))


def _toast_for(sku: str) -> str:
    if not sku:
        return ""
    row = db.catalogue()["skus"].get(sku)
    if not row:
        return "Added to your bag"
    return f"Added — {row['style_name']}, {row['colour']}, size {row['size']}"


# ---------------------------------------------------------------------------
# Listing
# ---------------------------------------------------------------------------


@router.get("/shop", response_class=HTMLResponse)
def listing(
    request: Request,
    category: str = "",
    colour: str = "",
    size: str = "",
    sale: int = 0,
    sort: str = "featured",
    added: str = "",
):
    cat = db.catalogue()
    rows = list(cat["styles"])

    if category:
        rows = [r for r in rows if r["category"] == category]
    if colour:
        rows = [r for r in rows if r["colour"] == colour]
    if size:
        rows = [r for r in rows if size in (r["sizes_in_stock"] or [])]
    if sale:
        rows = [r for r in rows if float(r["list_price"] or 0) > float(r["current_price"] or 0) + 1]

    if sort == "new":
        rows.sort(key=lambda r: (not r["is_new"], r["popularity_rank"]))
    elif sort == "price-low":
        rows.sort(key=lambda r: float(r["current_price"] or 0))
    elif sort == "price-high":
        rows.sort(key=lambda r: float(r["current_price"] or 0), reverse=True)
    elif sort == "discount":
        rows.sort(key=lambda r: float(r["list_price"] or 0) - float(r["current_price"] or 0), reverse=True)
    else:
        # Featured is popularity with sold-out styles pushed down. Showing what
        # someone cannot buy at the top of a page is the fastest way to make a
        # shop feel broken.
        rows.sort(key=lambda r: (not r["in_stock"], r["popularity_rank"]))

    sizes_here = sorted(
        {s for r in rows for s in (r["sizes_all"] or [])},
        key=lambda s: {"OS": 0, "XS": 1, "S": 2, "M": 3, "L": 4, "XL": 5}.get(s, int(s) if s.isdigit() else 99),
    )
    colours_here = sorted({r["colour"] for r in rows})

    def link(**over):
        """Build a filter URL that keeps every other filter intact.

        Values are URL-encoded, not HTML-escaped. They are different jobs: one
        makes a space survive the trip to the server, the other stops a quote
        closing the href attribute. The category names here contain neither, but
        writing the version that only works for today's data is how a filter
        breaks the day someone adds a category with an ampersand in it.
        """
        params = {"category": category, "colour": colour, "size": size, "sale": sale, "sort": sort}
        params.update(over)
        query = "&amp;".join(
            f"{k}={quote(str(v))}" for k, v in params.items() if v not in ("", 0, "featured")
        )
        return "/shop" + ("?" + query if query else "")

    colour_pills = "".join(
        f'<a class="pill swatch-pill {"on" if colour == c else ""}" href="{link(colour="" if colour == c else c)}">'
        f"{imagery.swatch(c)}{e(c)}</a>"
        for c in colours_here
    )
    size_pills = "".join(
        f'<a class="pill {"on" if size == s else ""}" href="{link(size="" if size == s else s)}">{e(s)}</a>'
        for s in sizes_here
    )
    sort_pills = "".join(
        f'<a class="pill {"on" if sort == k else ""}" href="{link(sort=k)}">{e(v)}</a>'
        for k, v in SORTS.items()
    )

    title = category or ("Sale" if sale else "All clothing")
    blurb = {
        "Dresses": "Cut for real days. Midi, maxi and mini in this season's palette.",
        "Tops": "Shirts, blouses and tees that work under everything else.",
        "Trousers": "Chino, denim and formal, in fits that survive a full day.",
        "Outerwear": "Jackets and coats built for the months that need them.",
        "Footwear": "Sneakers, heels and sandals, whole sizes 38 to 43.",
        "Accessories": "Bags, belts and scarves — one size, no guesswork.",
    }.get(category, "Every piece, from the newest arrivals to the last of the season.")
    if sale and not category:
        blurb = "Reductions taken as the season ages. What you see is what you pay."

    body = f"""
<div class="wrap">
  <div class="page-head">
    <div class="crumbs"><a href="/">Home</a> / {e(title)}</div>
    <h1>{e(title)}</h1>
    <p>{e(blurb)}</p>
  </div>

  <div class="filters">
    <div class="filter-group"><span class="label">Colour</span>{colour_pills}</div>
    <div class="filter-group"><span class="label">Size</span>{size_pills}</div>
    <span class="count">{len(rows)} styles</span>
  </div>
  <div class="filters" style="border:0;margin-bottom:2rem;padding-top:0">
    <div class="filter-group"><span class="label">Sort</span>{sort_pills}</div>
    {'<a class="pill" href="/shop">Clear all</a>' if (category or colour or size or sale) else ''}
  </div>

  {grid(rows, cat)}
</div>
"""
    items = _bag_items(request)
    return shell(title, body, _bag_count(items), active=category or ("sale" if sale else ""), toast=_toast_for(added))


# ---------------------------------------------------------------------------
# Product detail
# ---------------------------------------------------------------------------


@router.get("/product/{product_id}", response_class=HTMLResponse)
def product(request: Request, product_id: str, added: str = ""):
    cat = db.catalogue()
    row = cat["styles_by_id"].get(product_id)
    items = _bag_items(request)
    if not row:
        return shell(
            "Not found",
            '<div class="wrap"><div class="empty-state"><h2>We could not find that piece</h2>'
            '<p>It may have sold out and left the catalogue.</p>'
            '<p style="margin-top:1.5rem"><a class="btn ghost" href="/shop">Back to the collection</a></p></div></div>',
            _bag_count(items),
        )

    reserved = db.reserved_units()
    variants = cat["sizes"].get(product_id, [])
    colourways = cat["colourways"].get(row["style_id"], [])

    # RADIO INPUTS, not buttons, and the reason is that this has to work with
    # JavaScript switched off.
    #
    # The obvious build is a row of <button>s and a hidden field a script fills
    # in. That makes size selection - the one interaction on the page that must
    # happen before anything can be bought - depend on a script loading. A
    # labelled radio inside the form needs no script at all: choosing a size IS
    # setting the field the form posts. The script below only updates the stock
    # line, which is an enhancement nobody is blocked by.
    size_buttons = []
    for v in variants:
        left = max(0, int(v["on_hand"] or 0) - reserved.get(v["sku"], 0))
        gone = left <= 0
        size_buttons.append(
            f'<input class="size-opt" type="radio" name="sku" id="size-{e(v["sku"])}" '
            f'value="{e(v["sku"])}"{" disabled" if gone else ""}>'
            f'<label class="size-btn" for="size-{e(v["sku"])}" '
            f'data-size="{e(v["size"])}" data-left="{left}">{e(v["size"])}</label>'
        )

    thumbs = "".join(
        f'<a href="/product/{e(c["product_id"])}" class="{"on" if c["product_id"] == product_id else ""}" '
        f'title="{e(c["colour"])}">{imagery.product_image(c)}</a>'
        for c in colourways
    )

    fit = cat["fit"].get(row["category"])
    fit_note = ""
    if fit:
        reason = {
            "size": "the size ordered was wrong",
            "fit": "the fit was not right",
            "quality": "quality did not meet expectations",
            "changed_mind": "the customer simply changed their mind",
            "damaged": "the item arrived damaged",
        }.get(fit["reason"], fit["reason"])
        advice = ""
        if fit["reason"] in ("size", "fit"):
            advice = " If you are between sizes, take the larger one."
        fit_note = (
            f'<div class="fitnote"><b>Fit note.</b> Across {e(row["category"]).lower()}, '
            f'{int(fit["share"] or 0)}% of returns are because {e(reason)}.{advice} '
            f'This style is returned {float(row["return_rate_pct"] or 0):.0f}% of the time.</div>'
        )

    total_left = max(0, int(row["on_hand"] or 0) - sum(reserved.get(v["sku"], 0) for v in variants))
    sold_out = total_left <= 0

    body = f"""
<div class="wrap">
  <div class="crumbs" style="padding-top:1.6rem">
    <a href="/">Home</a> / <a href="/shop?category={quote(row['category'])}">{e(row['category'])}</a> / {e(row['style_name'])}
  </div>
  <div class="pdp">
    <div class="gallery">
      <div class="main">{imagery.product_image(row)}</div>
      <div class="thumbs">{thumbs}</div>
    </div>

    <div class="info">
      <div class="eyebrow">{e(row['subcategory'])} · {e(row['season'])}</div>
      <h1>{e(row['style_name'])}</h1>
      <div class="colourline">{e(row['colour'])}</div>

      <div class="priceline">{_price_block(row)}</div>
      <div class="tax">Inclusive of all taxes</div>

      {fit_note}

      <form method="post" action="/bag/add" id="add-form">
        <input type="hidden" name="back" value="/product/{e(product_id)}">
        <fieldset style="border:0;padding:0;margin:0">
          <legend class="eyebrow" style="margin-top:1.4rem;padding:0">Select a size</legend>
          <div class="sizes">{"".join(size_buttons)}</div>
        </fieldset>
        <div class="stocknote" id="stocknote">{
            'Sold out in every size' if sold_out else f'{total_left} pieces across all sizes'
        }</div>
        <div class="row-actions">
          <div class="qty">
            <button type="button" data-step="-1" aria-label="Fewer">−</button>
            <input name="qty" value="1" inputmode="numeric" aria-label="Quantity">
            <button type="button" data-step="1" aria-label="More">+</button>
          </div>
          <button class="btn block" id="add-btn"{" disabled" if sold_out else ""}>
            {"Sold out" if sold_out else "Add to bag"}
          </button>
        </div>
      </form>

      <div style="margin-top:2.2rem">
        <details class="acc" open><summary>Details</summary>
          <div class="body">
            <ul class="specs">
              <li><span>Style</span><span>{e(row['style_id'])}</span></li>
              <li><span>Colour</span><span>{e(row['colour'])}</span></li>
              <li><span>Category</span><span>{e(row['category'])} · {e(row['subcategory'])}</span></li>
              <li><span>Season</span><span>{e(row['season'])}</span></li>
              <li><span>Sizes made</span><span>{e(", ".join(row['sizes_all'] or []))}</span></li>
              <li><span>Units sold to date</span><span>{count(row['units_sold'])}</span></li>
            </ul>
          </div>
        </details>
        <details class="acc"><summary>Delivery &amp; returns</summary>
          <div class="body">
            Shipped from the store holding stock nearest you, usually in two working days.
            Delivery is ₹{rupees(cart.DELIVERY_FEE)}, free over ₹{rupees(cart.FREE_DELIVERY_OVER)}.
            Returns are accepted for 30 days in original condition. Returned items are
            netted off revenue the same night, which is why the numbers on the operations
            side are honest ones.
          </div>
        </details>
        <details class="acc"><summary>Where this data comes from</summary>
          <div class="body">
            Price, size availability and the fit note above are read from
            <code>{e(db.CATALOG)}.gold</code> in Unity Catalog — the same marts the
            merchandising team works from. The catalogue is held in this process and
            refreshed in the background, so browsing never queries the warehouse.
          </div>
        </details>
      </div>
    </div>
  </div>
</div>
"""
    return shell(row["style_name"], body, _bag_count(items), active=row["category"], toast=_toast_for(added))


# ---------------------------------------------------------------------------
# Bag
# ---------------------------------------------------------------------------


def _set_bag(response, items: list[dict]):
    response.set_cookie(
        cart.COOKIE,
        cart.encode(items),
        max_age=60 * 60 * 24 * 14,
        httponly=True,
        samesite="lax",
        # The site is served over HTTPS by Container Apps ingress; there is no
        # http listener to fall back to, so this costs nothing and closes the
        # one case where the cookie could cross the wire in clear.
        secure=True,
    )
    return response


def _safe_path(value: str, fallback: str = "/bag") -> str:
    """Only ever redirect somewhere on this site.

    `back` arrives from a form field, and a form on someone else's page can post
    to this endpoint just as easily as ours. Without this check the shop becomes
    an open redirector - a link that looks like it goes to the store and lands on
    a phishing page, with our domain doing the vouching. Leading `//` is the case
    people miss: the browser reads it as protocol-relative and leaves the site.
    """
    if value.startswith("/") and not value.startswith("//"):
        return value
    return fallback


def _qty(raw: str, fallback: int = 1) -> int:
    try:
        return max(0, min(cart.MAX_QTY, int(str(raw).strip())))
    except (TypeError, ValueError):
        return fallback


@router.post("/bag/add")
def bag_add(request: Request, sku: str = Form(""), qty: str = Form("1"), back: str = Form("/bag")):
    items = _bag_items(request)
    target = _safe_path(back, "/bag")
    if sku and sku in db.catalogue()["skus"]:
        items = cart.add(items, sku, _qty(qty, 1) or 1)
        target = f"{target}{'&' if '?' in target else '?'}added={quote(sku)}"
    return _set_bag(RedirectResponse(target, status_code=303), items)


@router.post("/bag/set")
def bag_set(request: Request, sku: str = Form(""), qty: str = Form("0")):
    items = cart.set_quantity(_bag_items(request), sku, _qty(qty, 0))
    return _set_bag(RedirectResponse("/bag", status_code=303), items)


@router.get("/bag", response_class=HTMLResponse)
def bag(request: Request):
    items = _bag_items(request)
    priced = cart.priced(items)

    if not priced["lines"]:
        return shell(
            "Your bag",
            '<div class="wrap"><div class="empty-state"><h2>Your bag is empty</h2>'
            "<p>Nothing has been added yet.</p>"
            '<p style="margin-top:1.5rem"><a class="btn" href="/shop">Start shopping</a></p></div></div>',
            0,
        )

    lines = ""
    for line in priced["lines"]:
        short = (
            f'<div class="notice bad" style="margin:.6rem 0 0;padding:.5rem .7rem">'
            f"Only {line['available']} left — reduce the quantity to check out.</div>"
            if line["short"]
            else ""
        )
        lines += f"""<div class="bag-line">
          <a class="frame" href="/product/{e(line['product_id'])}">{imagery.product_image(line)}</a>
          <div>
            <a class="name" href="/product/{e(line['product_id'])}">{e(line['style_name'])}</a>
            <div class="sub">{e(line['colour'])} · Size {e(line['size'])} · {e(line['sku'])}</div>
            <div class="line-actions">
              <form method="post" action="/bag/set" class="qty" data-autosubmit="1">
                <input type="hidden" name="sku" value="{e(line['sku'])}">
                <button type="button" data-step="-1" aria-label="Fewer">−</button>
                <input name="qty" value="{line['quantity']}" inputmode="numeric" aria-label="Quantity">
                <button type="button" data-step="1" aria-label="More">+</button>
              </form>
              <form method="post" action="/bag/set">
                <input type="hidden" name="sku" value="{e(line['sku'])}">
                <input type="hidden" name="qty" value="0">
                <button class="linkish">Remove</button>
              </form>
            </div>
            {short}
          </div>
          <div style="text-align:right">
            <div>{price(line['line_total'])}</div>
            <div class="sub">{price(line['current_price'])} each</div>
          </div>
        </div>"""

    body = f"""
<div class="wrap">
  <div class="page-head"><h1>Your bag</h1><p>{priced['items']} items</p></div>
  <div class="two-col">
    <div>{lines}</div>
    {_summary(priced, checkout=True)}
  </div>
</div>
"""
    return shell("Your bag", body, _bag_count(items))


def _summary(priced: dict, checkout: bool = False, action: str = "") -> str:
    saved = (
        f'<div class="sum-row"><span>You saved</span><span class="save">−{price(priced["saved"])}</span></div>'
        if priced["saved"] > 0
        else ""
    )
    if priced["to_free_delivery"] > 0:
        pct_done = 100 - (priced["to_free_delivery"] / cart.FREE_DELIVERY_OVER * 100)
        nudge = f"""<div class="sum-row" style="display:block">
            <div>Add {price(priced['to_free_delivery'])} for free delivery</div>
            <div class="progress"><i style="width:{pct_done:.0f}%"></i></div>
          </div>"""
    else:
        nudge = '<div class="sum-row"><span>Delivery</span><span class="save">Free</span></div>'

    cta = ""
    if checkout:
        disabled = " disabled" if priced["short"] else ""
        cta = (
            f'<a class="btn block" href="/checkout" style="margin-top:1.2rem">Checkout</a>'
            if not priced["short"]
            else f'<button class="btn block" style="margin-top:1.2rem"{disabled}>Adjust quantities to continue</button>'
        )
    elif action:
        cta = action

    delivery_row = (
        f'<div class="sum-row"><span>Delivery</span><span>{price(priced["delivery"])}</span></div>'
        if priced["delivery"]
        else ""
    )

    return f"""<div class="summary">
      <h2>Summary</h2>
      <div class="sum-row"><span>Subtotal ({priced['items']} items)</span><span>{price(priced['subtotal'])}</span></div>
      {saved}
      {delivery_row}
      {nudge}
      <div class="sum-row total"><span>Total</span><span>{price(priced['total'])}</span></div>
      {cta}
      <p style="font-size:.76rem;color:var(--muted);margin:1.1rem 0 0;line-height:1.7">
        No payment is taken. Placing an order writes a real row to the order book that the
        operations console then has to work through.</p>
    </div>"""


# ---------------------------------------------------------------------------
# Checkout
# ---------------------------------------------------------------------------


@router.get("/checkout", response_class=HTMLResponse)
def checkout_form(request: Request, error: str = ""):
    items = _bag_items(request)
    priced = cart.priced(items)
    if not priced["lines"]:
        return RedirectResponse("/bag", status_code=303)

    warning = f'<div class="notice bad">{e(error)}</div>' if error else ""
    body = f"""
<div class="wrap">
  <div class="page-head"><h1>Checkout</h1><p>Delivery details. No card is asked for and none is stored.</p></div>
  <div class="two-col">
    <form method="post" action="/checkout">
      {warning}
      <div class="notice">This is a demonstration. Submitting writes an order to
        <code>{e(db.CATALOG)}.ops.orders</code> and nothing is charged.</div>
      <div class="field"><label for="name">Full name</label>
        <input id="name" name="name" required maxlength="80" autocomplete="name"></div>
      <div class="field-row">
        <div class="field"><label for="email">Email</label>
          <input id="email" name="email" type="email" required maxlength="120" autocomplete="email"></div>
        <div class="field"><label for="phone">Phone</label>
          <input id="phone" name="phone" maxlength="20" autocomplete="tel"></div>
      </div>
      <div class="field"><label for="address">Address</label>
        <textarea id="address" name="address" rows="3" required maxlength="200" autocomplete="street-address"></textarea></div>
      <div class="field-row">
        <div class="field"><label for="city">City</label>
          <input id="city" name="city" required maxlength="60" autocomplete="address-level2"></div>
        <div class="field"><label for="postcode">PIN code</label>
          <input id="postcode" name="postcode" required maxlength="10" inputmode="numeric"></div>
      </div>
      <button class="btn block" style="margin-top:1rem">Place order</button>
    </form>
    {_summary(priced)}
  </div>
</div>
"""
    return shell("Checkout", body, _bag_count(items))


@router.post("/checkout")
def checkout_submit(
    request: Request,
    name: str = Form(...),
    email: str = Form(...),
    phone: str = Form(""),
    address: str = Form(...),
    city: str = Form(...),
    postcode: str = Form(...),
):
    items = _bag_items(request)
    priced = cart.priced(items)

    if not priced["lines"]:
        return RedirectResponse("/bag", status_code=303)
    if priced["short"]:
        return RedirectResponse("/checkout?error=Someone+bought+the+last+one.+Adjust+your+bag.", status_code=303)

    customer = {
        "name": name.strip()[:80],
        "email": email.strip()[:120],
        "phone": phone.strip()[:20],
        "address": " ".join(address.split())[:200],
        "city": city.strip()[:60],
        "postcode": postcode.strip()[:10],
    }

    try:
        order_id = db.place_order(customer, priced["lines"], priced)
    except Exception:
        # The detail goes to the log, not to the page. A stack trace on a
        # checkout screen tells an attacker your table names and tells a
        # customer nothing they can act on.
        log.exception("order write failed")
        return RedirectResponse(
            "/checkout?error=We+could+not+place+that+order.+Please+try+again+in+a+moment.",
            status_code=303,
        )

    response = RedirectResponse(f"/order/{order_id}", status_code=303)
    return _set_bag(response, [])


# ---------------------------------------------------------------------------
# Orders
# ---------------------------------------------------------------------------


def _track(status: str) -> str:
    if status == "cancelled":
        return """<div class="track"><div class="step cancelled done"><i></i>Cancelled</div></div>"""
    reached = TRACK_STEPS.index(status) if status in TRACK_STEPS else 0
    steps = "".join(
        f'<div class="step {"done" if i <= reached else ""}"><i></i>{s.title()}</div>'
        for i, s in enumerate(TRACK_STEPS)
    )
    return f'<div class="track">{steps}</div>'


@router.get("/order/{order_id}", response_class=HTMLResponse)
def order_page(request: Request, order_id: str):
    items = _bag_items(request)
    try:
        order = db.get_order(order_id)
    except Exception:
        log.exception("order read failed")
        order = None

    if not order:
        return shell(
            "Order not found",
            '<div class="wrap"><div class="empty-state"><h2>We could not find that order</h2>'
            "<p>Check the reference, or look it up by email.</p>"
            '<p style="margin-top:1.5rem"><a class="btn ghost" href="/orders">Find my order</a></p></div></div>',
            _bag_count(items),
        )

    lines = "".join(
        f"""<tr>
          <td class="name">{e(l['style_name'])}</td>
          <td>{e(l['colour'])}</td>
          <td>{e(l['size'])}</td>
          <td class="num">{l['quantity']}</td>
          <td class="num">{price(l['unit_price'])}</td>
          <td class="num">{price(l['line_total'])}</td>
        </tr>"""
        for l in order["lines"]
    )

    body = f"""
<div class="wrap">
  <div class="confirm">
    <div class="tick">✓</div>
    <h1>Thank you, {e((order['customer_name'] or '').split(' ')[0])}</h1>
    <p style="color:var(--ink-soft)">Your order is with the team. Reference
      <span class="oid">{e(order['order_id'])}</span></p>
  </div>

  {_track(order['status'])}

  <div class="two-col">
    <div>
      <h2 style="font-family:var(--display);font-weight:400;font-size:1.3rem">What you ordered</h2>
      <table class="lines">
        <thead><tr><th>Style</th><th>Colour</th><th>Size</th>
          <th class="num">Qty</th><th class="num">Each</th><th class="num">Total</th></tr></thead>
        <tbody>{lines}</tbody>
      </table>
      <p style="color:var(--muted);font-size:.84rem;margin-top:1.5rem">
        Placed {when(order['placed_at'])} · last updated {when(order['updated_at'])}
      </p>
    </div>
    <div class="summary">
      <h2>Delivering to</h2>
      <p style="font-size:.9rem;line-height:1.8;color:var(--ink-soft);margin:0 0 1.2rem">
        {e(order['customer_name'])}<br>{e(order['address_line'])}<br>
        {e(order['city'])} {e(order['postcode'])}<br>{e(order['customer_email'])}
      </p>
      <div class="sum-row"><span>Items</span><span>{count(order['item_count'])}</span></div>
      <div class="sum-row"><span>Subtotal</span><span>{price(order['subtotal'])}</span></div>
      <div class="sum-row"><span>Delivery</span><span>{price(order['delivery_fee']) if order['delivery_fee'] else 'Free'}</span></div>
      <div class="sum-row total"><span>Total</span><span>{price(order['total'])}</span></div>
      <a class="btn ghost block" href="/shop" style="margin-top:1.2rem">Continue shopping</a>
    </div>
  </div>
</div>
"""
    return shell(f"Order {order['order_id']}", body, _bag_count(items))


@router.get("/orders", response_class=HTMLResponse)
def order_lookup(request: Request, email: str = ""):
    items = _bag_items(request)
    results = ""
    if email:
        try:
            found = db.orders_by_email(email)
        except Exception:
            log.exception("order lookup failed")
            found = []
        if found:
            rows = "".join(
                f"""<tr>
                  <td class="name"><a href="/order/{e(o['order_id'])}">{e(o['order_id'])}</a></td>
                  <td>{day(o['placed_at'])}</td>
                  <td>{e(str(o['status']).title())}</td>
                  <td class="num">{count(o['item_count'])}</td>
                  <td class="num">{price(o['total'])}</td>
                </tr>"""
                for o in found
            )
            results = f"""<table class="lines" style="margin-top:2rem">
              <thead><tr><th>Reference</th><th>Placed</th><th>Status</th>
                <th class="num">Items</th><th class="num">Total</th></tr></thead>
              <tbody>{rows}</tbody></table>"""
        else:
            results = '<div class="notice" style="margin-top:2rem">No orders found for that email.</div>'

    body = f"""
<div class="wrap">
  <div class="page-head"><h1>Find your order</h1>
    <p>Enter the email you used at checkout.</p></div>
  <div style="max-width:460px;padding:2rem 0 4rem">
    <form method="get" action="/orders">
      <div class="field"><label for="email">Email</label>
        <input id="email" name="email" type="email" required value="{e(email)}"></div>
      <button class="btn">Find orders</button>
    </form>
    {results}
  </div>
</div>
"""
    return shell("Find your order", body, _bag_count(items))


@router.get("/health")
def health():
    """Liveness only — deliberately does NOT touch Databricks.

    A health check that queried the warehouse would wake it on every probe, and
    the platform probes constantly. The thing meant to report that the app is
    alive would end up preventing the warehouse from ever sleeping, which on a
    serverless SKU is the most expensive kind of monitoring there is.
    """
    return {"status": "ok", "role": "shop"}


WARMING = """<!doctype html>
<html lang="en"><head><meta charset="utf-8">
<meta name="viewport" content="width=device-width,initial-scale=1">
<title>{brand} — one moment</title>{css}</head>
<body><main class="wrap" style="max-width:38rem;padding:6rem 1.5rem">
  <div class="wordmark">{brand}</div>
  <h1 style="font-family:var(--display);font-weight:400;font-size:1.8rem;margin:2rem 0 .8rem">
    The shop is waking up</h1>
  <p style="color:var(--ink-soft)">The catalogue is served from a warehouse that stops when
    nobody is using it, and starting it takes a few seconds. This page will work on reload.</p>
  <p style="color:var(--muted);font-size:.86rem;margin-top:2rem">If reloading does not help,
    the medallion pipeline has not produced the gold layer yet. Run the
    <code>fashion-medallion</code> job once and come back.</p>
  <p style="margin-top:2rem"><a class="btn" href="/">Try again</a></p>
</main></body></html>"""


def build() -> FastAPI:
    app = FastAPI(title=f"{BRAND} storefront", docs_url=None, redoc_url=None)
    app.include_router(router)

    @app.exception_handler(Exception)
    async def warming(request: Request, exc: Exception):
        """Anything unhandled becomes one honest page, and the detail goes to the log.

        The two things that actually reach here are a warehouse still starting
        and a gold layer that does not exist yet. Both are transient and both
        are fixed by waiting or by running the pipeline, so the page says so.

        What it deliberately does NOT say is what went wrong internally. The
        previous version rendered `str(exc)` into the browser, which on a
        publicly-resolvable FQDN hands out table names and hostnames to anyone
        who can provoke an error.
        """
        log.exception("unhandled request error: %s", request.url.path)
        return HTMLResponse(
            WARMING.format(brand=e(BRAND), css=SHOP_CSS),
            status_code=503,
        )

    return app
