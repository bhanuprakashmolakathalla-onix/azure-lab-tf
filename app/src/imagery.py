"""Product imagery, drawn rather than fetched.

A clothing site without pictures is a spreadsheet with a nicer font, so this
module draws one. Every product gets a flat vector garment in its own colour,
picked by category and shaped by subcategory - a maxi dress is longer than a
mini, a coat is longer than a jacket, a blouse has sleeves and a t-shirt does
not.

WHY DRAWN AND NOT PHOTOGRAPHED, which is a real constraint rather than a
preference:

  - the container reaches Databricks over a private endpoint and has no reason
    to be allowed out to an image CDN, so a remote <img> is a hole in the
    network posture for the sake of decoration
  - storing photographs would mean a blob container, a public path or a signed
    URL scheme, and a second thing to tear down
  - the generator invents the products, so no photograph of them exists

Vectors cost nothing, need no network, tear down with the container, and are
crisp at any size. The colours are the ones the data actually carries, so the
page is showing you the catalogue rather than illustrating it.
"""

from .fmt import e

# The seven colours the generator uses. Values are chosen to read as fabric
# rather than as UI: nothing fully saturated, nothing pure black.
COLOURS = {
    "Black": "#26241f",
    "Ivory": "#ebe3d4",
    "Navy": "#233150",
    "Olive": "#5d6448",
    "Rust": "#a8532e",
    "Sand": "#ccb492",
    "Burgundy": "#6d2434",
}

# Studio backdrops. Four warm neutrals, picked per product so a grid of cards
# has some rhythm without any card shouting.
BACKDROPS = ["#f5f2eb", "#efeae0", "#f2eee8", "#eae7df"]

DEFAULT = "#8d8577"


def _hex_to_rgb(value: str) -> tuple[int, int, int]:
    value = value.lstrip("#")
    return int(value[0:2], 16), int(value[2:4], 16), int(value[4:6], 16)


def _shade(value: str, amount: float) -> str:
    """Darken (negative) or lighten (positive) by a fraction, clamped."""
    r, g, b = _hex_to_rgb(value)
    if amount >= 0:
        r, g, b = (int(c + (255 - c) * amount) for c in (r, g, b))
    else:
        r, g, b = (int(c * (1 + amount)) for c in (r, g, b))
    return "#%02x%02x%02x" % (max(0, min(255, r)), max(0, min(255, g)), max(0, min(255, b)))


def colour_of(name: str) -> str:
    return COLOURS.get(name, DEFAULT)


def _backdrop(product_id: str) -> str:
    return BACKDROPS[sum(ord(c) for c in (product_id or "x")) % len(BACKDROPS)]


# ---------------------------------------------------------------------------
# Garments. Each returns the marks that sit inside a 200 x 280 viewBox.
#
# `fill` is the product's colour, `line` a darker version of it for seams and
# outlines, and `back` the backdrop - used to cut a neckline out of a garment
# without needing a mask.
# ---------------------------------------------------------------------------


def _dress(sub: str, fill: str, line: str, back: str) -> str:
    hem = {"Mini": 168, "Midi": 208, "Maxi": 248}.get(sub, 208)
    return f"""
      <path d="M74,60 L126,60 L133,80 L124,120 L153,{hem} L47,{hem} L76,120 L67,80 Z"
            fill="{fill}" stroke="{line}" stroke-width="1.2" stroke-linejoin="round"/>
      <path d="M76,120 L124,120" stroke="{line}" stroke-width="1.2" fill="none" opacity="0.7"/>
      <path d="M100,124 L100,{hem - 4}" stroke="{line}" stroke-width="1" fill="none" opacity="0.35"/>
      <ellipse cx="100" cy="60" rx="15" ry="7" fill="{back}"/>
      <path d="M85,61 A15,9 0 0 0 115,61" fill="none" stroke="{line}" stroke-width="1.2"/>
    """


def _top(sub: str, fill: str, line: str, back: str) -> str:
    long_sleeve = sub in ("Shirt", "Blouse")
    if long_sleeve:
        sleeves = f"""
          <path d="M72,66 L49,82 L57,160 L75,155 Z" fill="{fill}" stroke="{line}" stroke-width="1.2" stroke-linejoin="round"/>
          <path d="M128,66 L151,82 L143,160 L125,155 Z" fill="{fill}" stroke="{line}" stroke-width="1.2" stroke-linejoin="round"/>
        """
    else:
        sleeves = f"""
          <path d="M72,66 L50,82 L60,112 L78,104 Z" fill="{fill}" stroke="{line}" stroke-width="1.2" stroke-linejoin="round"/>
          <path d="M128,66 L150,82 L140,112 L122,104 Z" fill="{fill}" stroke="{line}" stroke-width="1.2" stroke-linejoin="round"/>
        """

    collar = ""
    if sub == "Shirt":
        collar = f"""
          <path d="M100,84 L86,64 L94,62 Z" fill="{_shade(fill, 0.10)}" stroke="{line}" stroke-width="1"/>
          <path d="M100,84 L114,64 L106,62 Z" fill="{_shade(fill, 0.10)}" stroke="{line}" stroke-width="1"/>
          <path d="M100,88 L100,186" stroke="{line}" stroke-width="1" fill="none" opacity="0.5"/>
        """

    return f"""
      {sleeves}
      <path d="M72,66 L128,66 L128,188 L72,188 Z" fill="{fill}" stroke="{line}" stroke-width="1.2" stroke-linejoin="round"/>
      <ellipse cx="100" cy="66" rx="14" ry="6" fill="{back}"/>
      <path d="M86,67 A14,8 0 0 0 114,67" fill="none" stroke="{line}" stroke-width="1.2"/>
      {collar}
    """


def _trousers(sub: str, fill: str, line: str, back: str) -> str:
    seam = ""
    if sub == "Denim":
        seam = f"""
          <path d="M78,86 L84,240" stroke="{_shade(fill, 0.22)}" stroke-width="1" fill="none" opacity="0.6"/>
          <path d="M122,86 L116,240" stroke="{_shade(fill, 0.22)}" stroke-width="1" fill="none" opacity="0.6"/>
        """
    return f"""
      <path d="M70,78 L130,78 L127,250 L106,250 L100,150 L94,250 L73,250 Z"
            fill="{fill}" stroke="{line}" stroke-width="1.2" stroke-linejoin="round"/>
      <rect x="69" y="66" width="62" height="14" rx="3" fill="{_shade(fill, -0.12)}" stroke="{line}" stroke-width="1.2"/>
      <path d="M100,80 L100,148" stroke="{line}" stroke-width="1" fill="none" opacity="0.45"/>
      {seam}
    """


def _outerwear(sub: str, fill: str, line: str, back: str) -> str:
    hem = 236 if sub == "Coat" else 192
    buttons = "".join(
        f'<circle cx="104" cy="{y}" r="3" fill="{_shade(fill, -0.3)}"/>'
        for y in range(112, hem - 20, 34)
    )
    return f"""
      <path d="M70,64 L47,84 L56,{hem - 30} L74,{hem - 36} Z" fill="{_shade(fill, -0.06)}" stroke="{line}" stroke-width="1.2" stroke-linejoin="round"/>
      <path d="M130,64 L153,84 L144,{hem - 30} L126,{hem - 36} Z" fill="{_shade(fill, -0.06)}" stroke="{line}" stroke-width="1.2" stroke-linejoin="round"/>
      <path d="M70,64 L130,64 L136,{hem} L64,{hem} Z" fill="{fill}" stroke="{line}" stroke-width="1.2" stroke-linejoin="round"/>
      <path d="M100,64 L84,66 L98,120 Z" fill="{_shade(fill, 0.12)}" stroke="{line}" stroke-width="1"/>
      <path d="M100,64 L116,66 L102,120 Z" fill="{_shade(fill, 0.12)}" stroke="{line}" stroke-width="1"/>
      <path d="M100,120 L100,{hem - 4}" stroke="{line}" stroke-width="1.2" fill="none" opacity="0.6"/>
      {buttons}
    """


def _footwear(sub: str, fill: str, line: str, back: str) -> str:
    if sub == "Heel":
        return f"""
          <path d="M52,198 C52,166 68,150 90,148 C108,147 120,160 128,178 L152,196 L152,200 L52,200 Z"
                fill="{fill}" stroke="{line}" stroke-width="1.2" stroke-linejoin="round"/>
          <path d="M50,200 L154,200 L154,208 L50,208 Z" fill="{_shade(fill, -0.28)}" stroke="{line}" stroke-width="1"/>
          <path d="M138,208 L152,208 L156,242 L146,242 Z" fill="{_shade(fill, -0.28)}" stroke="{line}" stroke-width="1"/>
          <path d="M74,168 C90,176 112,182 132,184" fill="none" stroke="{line}" stroke-width="1" opacity="0.5"/>
        """
    if sub == "Sandal":
        return f"""
          <path d="M46,192 Q100,182 156,190 L158,206 Q100,216 44,206 Z"
                fill="{_shade(fill, -0.22)}" stroke="{line}" stroke-width="1.2"/>
          <path d="M62,192 C84,168 108,168 126,186" fill="none" stroke="{fill}" stroke-width="9" stroke-linecap="round"/>
          <path d="M76,190 C96,176 112,176 128,192" fill="none" stroke="{_shade(fill, 0.16)}" stroke-width="7" stroke-linecap="round"/>
          <path d="M52,196 L60,178" stroke="{fill}" stroke-width="6" stroke-linecap="round"/>
        """
    return f"""
      <path d="M46,192 C46,166 62,154 84,157 L112,172 C134,178 152,182 157,192 L157,199 L46,199 Z"
            fill="{fill}" stroke="{line}" stroke-width="1.2" stroke-linejoin="round"/>
      <path d="M42,199 L160,199 Q165,210 155,213 L48,213 Q39,210 42,199 Z"
            fill="{_shade(fill, 0.24)}" stroke="{line}" stroke-width="1.2"/>
      <path d="M70,170 L92,178 M76,162 L98,171 M64,180 L86,187"
            stroke="{_shade(fill, -0.3)}" stroke-width="2" stroke-linecap="round" opacity="0.8"/>
      <path d="M120,176 C136,180 148,185 152,192" fill="none" stroke="{_shade(fill, -0.3)}" stroke-width="2" opacity="0.6"/>
    """


def _accessory(sub: str, fill: str, line: str, back: str) -> str:
    if sub == "Belt":
        holes = "".join(
            f'<circle cx="{x}" cy="163" r="2.4" fill="{back}"/>' for x in (142, 152, 162)
        )
        return f"""
          <path d="M40,150 L170,150 L170,176 L40,176 Z" fill="{fill}" stroke="{line}" stroke-width="1.2"/>
          <rect x="34" y="144" width="26" height="38" rx="4" fill="none" stroke="{_shade(fill, -0.35)}" stroke-width="6"/>
          <path d="M56,163 L84,163" stroke="{_shade(fill, -0.35)}" stroke-width="5" stroke-linecap="round"/>
          {holes}
        """
    if sub == "Scarf":
        return f"""
          <path d="M56,92 C96,78 106,130 146,112 L154,148 C112,166 100,116 60,132 Z"
                fill="{fill}" stroke="{line}" stroke-width="1.2" stroke-linejoin="round"/>
          <path d="M58,112 C98,98 106,148 148,130" fill="none" stroke="{_shade(fill, 0.18)}" stroke-width="2" opacity="0.7"/>
          <path d="M60,132 L56,168 M76,130 L74,166 M92,136 L92,172 M110,146 L112,180 M128,150 L132,184 L146,150"
                stroke="{fill}" stroke-width="3" stroke-linecap="round" fill="none"/>
        """
    return f"""
      <path d="M84,122 C84,96 116,96 116,122" fill="none" stroke="{_shade(fill, -0.3)}" stroke-width="5"/>
      <path d="M64,120 L136,120 L144,214 L56,214 Z" fill="{fill}" stroke="{line}" stroke-width="1.2" stroke-linejoin="round"/>
      <path d="M64,120 L136,120 L138,142 L62,142 Z" fill="{_shade(fill, 0.10)}" stroke="{line}" stroke-width="1"/>
      <rect x="92" y="132" width="16" height="12" rx="2" fill="{_shade(fill, -0.35)}"/>
    """


DRAWERS = {
    "Dresses": _dress,
    "Tops": _top,
    "Trousers": _trousers,
    "Outerwear": _outerwear,
    "Footwear": _footwear,
    "Accessories": _accessory,
}


def product_image(row: dict, css_class: str = "shot") -> str:
    """One product, drawn. `row` is a style_catalog or product_catalog row."""
    colour_name = row.get("colour") or ""
    fill = colour_of(colour_name)
    line = _shade(fill, -0.34)
    back = _backdrop(row.get("product_id") or row.get("sku") or "")
    draw = DRAWERS.get(row.get("category"), _top)
    marks = draw(row.get("subcategory") or "", fill, line, back)

    # Escaped like any other value out of the catalogue. It sits in an attribute,
    # which is the one place an unescaped quote does not merely look wrong - it
    # closes the attribute and everything after it becomes markup.
    label = e(f'{row.get("style_name") or "Product"} in {colour_name}')
    return f"""<svg viewBox="0 0 200 280" class="{css_class}" role="img" aria-label="{label}" preserveAspectRatio="xMidYMid meet">
      <rect width="200" height="280" fill="{back}"/>
      <ellipse cx="100" cy="256" rx="58" ry="8" fill="{_shade(back, -0.10)}" opacity="0.8"/>
      {marks}
    </svg>"""


def swatch(colour_name: str, selected: bool = False) -> str:
    """A colour chip. Bordered always, because Ivory on a light card vanishes."""
    fill = colour_of(colour_name)
    ring = "var(--ink)" if selected else _shade(fill, -0.3)
    width = 2 if selected else 1
    return (
        f'<svg viewBox="0 0 24 24" class="chip" role="img" aria-label="{e(colour_name)}">'
        f'<circle cx="12" cy="12" r="9" fill="{fill}" stroke="{ring}" stroke-width="{width}"/>'
        f"</svg>"
    )
