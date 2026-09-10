"""Formatting shared by the storefront and the ops console.

One module, because a price on a product page and the same price in an order
export disagreeing by a rupee is the kind of bug nobody reports and everybody
notices.
"""

from html import escape


def e(value) -> str:
    """Escape anything on its way into HTML.

    Every string below comes out of Unity Catalog. None of it is user input
    today - the generator wrote it - but a product name is exactly the field
    that becomes user-editable the moment a real merchandising system is
    plugged in, and escaping at the boundary is cheaper than auditing later.
    """
    return escape("" if value is None else str(value), quote=True)


def rupees(amount, decimals: int = 0) -> str:
    """Indian digit grouping: 12,34,567 rather than 1,234,567.

    The last three digits group as a thousand, everything above them groups in
    pairs. Python's own thousands separator cannot express this, so it is done
    by hand. Getting it wrong is instantly visible to anyone in the market the
    shop claims to serve.
    """
    try:
        value = float(amount or 0)
    except (TypeError, ValueError):
        return "0"

    sign = "-" if value < 0 else ""
    value = abs(value)
    whole = int(value)
    frac = value - whole

    digits = str(whole)
    if len(digits) > 3:
        head, tail = digits[:-3], digits[-3:]
        parts = []
        while len(head) > 2:
            parts.insert(0, head[-2:])
            head = head[:-2]
        if head:
            parts.insert(0, head)
        grouped = ",".join(parts) + "," + tail
    else:
        grouped = digits

    if decimals:
        return f"{sign}{grouped}.{int(round(frac * 10 ** decimals)):0{decimals}d}"
    return f"{sign}{grouped}"


def price(amount) -> str:
    return "₹" + rupees(amount)


def compact(amount) -> str:
    """Lakh and crore, because that is how the numbers are read here.

    A merchandiser in Bengaluru reads 12.4L faster than 1,240,000, and an axis
    label has no room for either spelled out.
    """
    try:
        value = float(amount or 0)
    except (TypeError, ValueError):
        return "0"

    if abs(value) >= 10_000_000:
        return f"₹{value / 10_000_000:.2f}Cr"
    if abs(value) >= 100_000:
        return f"₹{value / 100_000:.1f}L"
    if abs(value) >= 1_000:
        return f"₹{value / 1_000:.1f}k"
    return "₹" + rupees(value)


def count(value) -> str:
    try:
        return rupees(int(value or 0))
    except (TypeError, ValueError):
        return "0"


def pct(value, decimals: int = 1) -> str:
    try:
        return f"{float(value or 0):.{decimals}f}%"
    except (TypeError, ValueError):
        return "0%"


def when(value) -> str:
    """Timestamps as '12 Sep, 14:30'. Never an ISO string in front of a person."""
    if value is None:
        return "—"
    try:
        return value.strftime("%d %b, %H:%M")
    except AttributeError:
        return str(value)[:16].replace("T", " ")


def day(value) -> str:
    if value is None:
        return "—"
    try:
        return value.strftime("%d %b")
    except AttributeError:
        return str(value)[:10]
