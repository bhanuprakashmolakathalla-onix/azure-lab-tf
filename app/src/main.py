"""Entry point. One image, two applications, chosen by APP_ROLE.

WHY ONE IMAGE AND NOT TWO

The storefront and the console share the connection handling, the cache, the
formatting and the product drawings. Splitting them into separate images would
duplicate all of it, or introduce a shared wheel to publish and version, and
would double the build time and the registry storage for a lab that lives a day.

They are still two SEPARATE deployments with separate identities and separate
grants - the shop cannot read silver, the console cannot write an order. The
boundary that matters is the identity, not the container image, and conflating
those two is how people end up believing a shared binary is a shared privilege.

APP_ROLE is set by Terraform, per container app. Anything other than "console"
serves the shop, because if that variable is ever lost the safe failure is the
public site rather than the internal one.
"""

import logging
import os

logging.basicConfig(level=os.getenv("LOG_LEVEL", "INFO"))

ROLE = os.getenv("APP_ROLE", "shop").strip().lower()

if ROLE == "console":
    from .console import build
else:
    from .shop import build

app = build()
