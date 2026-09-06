"""Hand-drawn SVG charts.

No charting library. Every mark is emitted here, which means full control over
the things libraries get wrong by default: thick marks, heavy gridlines, a number
on every point, and value-ramps on nominal categories.

Palette roles are CSS custom properties defined once in the page, so the marks
below reference roles (--series-1) rather than hex. Colours are the validated
dark-mode steps; the two-series pair was checked with the palette validator
(adjacent CVD ΔE 26.8, normal-vision 31.8, both well clear of the floors).
"""

from html import escape

# Geometry. The container includes the axis band so nothing gets a nested
# scrollbar - a common and very visible failure.
PAD_L, PAD_R, PAD_T, PAD_B = 44, 16, 16, 30


def _nice_max(value: float) -> float:
    """Round an axis maximum up to something a human would choose."""
    if value <= 0:
        return 1.0
    import math

    exp = math.floor(math.log10(value))
    frac = value / (10**exp)
    for step in (1, 1.5, 2, 2.5, 3, 4, 5, 7.5, 10):
        if frac <= step:
            return step * (10**exp)
    return 10 ** (exp + 1)


def _fmt(n: float, unit: str = "") -> str:
    if unit == "%":
        return f"{n:.1f}%"
    if abs(n) >= 10_000_000:
        return f"₹{n / 10_000_000:.2f}Cr"
    if abs(n) >= 100_000:
        return f"₹{n / 100_000:.1f}L"
    if abs(n) >= 1_000:
        return f"{n / 1000:.1f}k"
    return f"{n:,.0f}"


def line_chart(points, width=1000, height=260, unit="", label="", series_role="--series-1"):
    """Single-series trend. One axis, always — never two scales on one plot."""
    if not points:
        return "<p class='empty'>no data</p>"

    inner_w = width - PAD_L - PAD_R
    inner_h = height - PAD_T - PAD_B
    ymax = _nice_max(max(v for _, v in points))
    n = len(points)

    def x(i):
        return PAD_L + (inner_w * i / max(n - 1, 1))

    def y(v):
        return PAD_T + inner_h - (inner_h * v / ymax)

    path = " ".join(f"{'M' if i == 0 else 'L'}{x(i):.1f},{y(v):.1f}" for i, (_, v) in enumerate(points))
    area = f"M{x(0):.1f},{PAD_T + inner_h} " + " ".join(
        f"L{x(i):.1f},{y(v):.1f}" for i, (_, v) in enumerate(points)
    ) + f" L{x(n - 1):.1f},{PAD_T + inner_h} Z"

    # Hairline grid, solid — dashed gridlines read as thresholds.
    grid, ticks = [], []
    for f in (0, 0.25, 0.5, 0.75, 1.0):
        gy = PAD_T + inner_h - inner_h * f
        grid.append(f"<line x1='{PAD_L}' y1='{gy:.1f}' x2='{width - PAD_R}' y2='{gy:.1f}' class='grid'/>")
        ticks.append(f"<text x='{PAD_L - 8}' y='{gy + 4:.1f}' class='tick' text-anchor='end'>{_fmt(ymax * f, unit)}</text>")

    # X labels: first, middle, last only. A label per point is unreadable.
    xlabels = []
    for i in (0, n // 2, n - 1):
        if 0 <= i < n:
            anchor = "start" if i == 0 else "end" if i == n - 1 else "middle"
            xlabels.append(
                f"<text x='{x(i):.1f}' y='{height - 8}' class='tick' text-anchor='{anchor}'>{escape(str(points[i][0]))}</text>"
            )

    # Hover targets are full-height columns, so you never have to hit the line.
    hits = []
    col_w = inner_w / max(n - 1, 1)
    for i, (lbl, v) in enumerate(points):
        hits.append(
            f"<rect class='hit' x='{x(i) - col_w / 2:.1f}' y='{PAD_T}' width='{col_w:.1f}' height='{inner_h}' "
            f"data-x='{x(i):.1f}' data-y='{y(v):.1f}' data-label='{escape(str(lbl))}' data-value='{escape(_fmt(v, unit))}'/>"
        )

    # Direct-label the endpoint only — the extreme that matters, not every point.
    last_x, last_v = x(n - 1), points[-1][1]

    return f"""<svg viewBox="0 0 {width} {height}" class="chart" role="img" aria-label="{escape(label)}">
      <defs><linearGradient id="fade-{series_role[2:]}" x1="0" y1="0" x2="0" y2="1">
        <stop offset="0%" stop-color="var({series_role})" stop-opacity="0.22"/>
        <stop offset="100%" stop-color="var({series_role})" stop-opacity="0"/>
      </linearGradient></defs>
      {''.join(grid)}
      <path d="{area}" fill="url(#fade-{series_role[2:]})"/>
      <path d="{path}" fill="none" stroke="var({series_role})" stroke-width="2"
            stroke-linejoin="round" stroke-linecap="round"/>
      <circle cx="{last_x:.1f}" cy="{y(last_v):.1f}" r="4" fill="var({series_role})"
              stroke="var(--surface-1)" stroke-width="2"/>
      <text x="{last_x - 6:.1f}" y="{y(last_v) - 12:.1f}" class="endlabel" text-anchor="end">{_fmt(last_v, unit)}</text>
      {''.join(ticks)}{''.join(xlabels)}{''.join(hits)}
    </svg>"""


def bar_chart(items, width=480, height=260, unit="", label="", colors=None, icons=None):
    """Horizontal bars. One series, one colour — unless `colors` carries status."""
    if not items:
        return "<p class='empty'>no data</p>"

    row_h = 30
    height = PAD_T + len(items) * row_h + 14
    inner_w = width - PAD_L - PAD_R - 80
    vmax = _nice_max(max(v for _, v in items))

    rows = []
    for i, (name, v) in enumerate(items):
        y = PAD_T + i * row_h
        w = max(inner_w * v / vmax, 2)
        fill = f"var({colors[i]})" if colors else "var(--series-1)"
        icon = f"{icons[i]} " if icons else ""
        rows.append(
            f"""<g class="barrow" data-label="{escape(icon + str(name))}" data-value="{escape(_fmt(v, unit))}">
              <text x="0" y="{y + 15}" class="barlabel">{escape(icon + str(name))}</text>
              <rect class="bar" x="{PAD_L + 76}" y="{y + 4}" width="{w:.1f}" height="16" rx="4" fill="{fill}"/>
              <text x="{PAD_L + 84 + w:.1f}" y="{y + 16}" class="barvalue">{_fmt(v, unit)}</text>
            </g>"""
        )

    return f"""<svg viewBox="0 0 {width} {height}" class="chart" role="img" aria-label="{escape(label)}">
      {''.join(rows)}
    </svg>"""


def grouped_bars(groups, series_names, width=1000, height=260, unit="%", label=""):
    """Two series side by side. Legend is mandatory at >= 2 series."""
    if not groups:
        return "<p class='empty'>no data</p>"

    inner_w = width - PAD_L - PAD_R
    inner_h = height - PAD_T - PAD_B
    vmax = _nice_max(max(max(vals) for _, vals in groups))
    n = len(groups)
    slot = inner_w / n
    # 2px surface gap between adjacent fills, never a border around them.
    bar_w = min((slot - 14) / 2, 26)

    grid = []
    for f in (0, 0.5, 1.0):
        gy = PAD_T + inner_h - inner_h * f
        grid.append(f"<line x1='{PAD_L}' y1='{gy:.1f}' x2='{width - PAD_R}' y2='{gy:.1f}' class='grid'/>")
        grid.append(f"<text x='{PAD_L - 8}' y='{gy + 4:.1f}' class='tick' text-anchor='end'>{_fmt(vmax * f, unit)}</text>")

    marks = []
    for gi, (name, vals) in enumerate(groups):
        cx = PAD_L + slot * gi + slot / 2
        for si, v in enumerate(vals):
            h = max(inner_h * v / vmax, 2)
            bx = cx - bar_w - 1 + si * (bar_w + 2)
            marks.append(
                f"""<rect class="bar" x="{bx:.1f}" y="{PAD_T + inner_h - h:.1f}" width="{bar_w:.1f}" height="{h:.1f}"
                  rx="4" fill="var(--series-{si + 1})"
                  data-label="{escape(f'{name} · {series_names[si]}')}" data-value="{escape(_fmt(v, unit))}"/>"""
            )
        marks.append(f"<text x='{cx:.1f}' y='{height - 8}' class='tick' text-anchor='middle'>{escape(str(name))}</text>")

    return f"""<svg viewBox="0 0 {width} {height}" class="chart" role="img" aria-label="{escape(label)}">
      {''.join(grid)}{''.join(marks)}
    </svg>"""


def sparkline(values, width=120, height=32, role="--series-1"):
    """A stat tile's trend. No axes, no labels — the tile's number is the message."""
    if len(values) < 2:
        return ""
    lo, hi = min(values), max(values)
    span = (hi - lo) or 1
    pts = [
        (width * i / (len(values) - 1), height - 3 - (height - 6) * (v - lo) / span)
        for i, v in enumerate(values)
    ]
    d = " ".join(f"{'M' if i == 0 else 'L'}{x:.1f},{y:.1f}" for i, (x, y) in enumerate(pts))
    return (
        f"<svg viewBox='0 0 {width} {height}' class='spark' aria-hidden='true'>"
        f"<path d='{d}' fill='none' stroke='var({role})' stroke-width='1.5' "
        f"stroke-linecap='round' stroke-linejoin='round'/></svg>"
    )


def table(headers, rows, unit_cols=()):
    """The table view. Every chart has one — values are never color-only."""
    head = "".join(f"<th>{escape(h)}</th>" for h in headers)
    body = []
    for r in rows:
        cells = "".join(
            f"<td class='num'>{escape(str(c))}</td>" if i in unit_cols else f"<td>{escape(str(c))}</td>"
            for i, c in enumerate(r)
        )
        body.append(f"<tr>{cells}</tr>")
    return f"<table class='data'><thead><tr>{head}</tr></thead><tbody>{''.join(body)}</tbody></table>"
