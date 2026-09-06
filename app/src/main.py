"""Taxi daily summary — a read-only API over the gold layer.

Deliberately small. The interesting part is not the application, it is the
authentication path and the fact that nothing here holds a credential:

    Container App  ->  user-assigned managed identity
                   ->  Azure token for the AzureDatabricks resource
                   ->  Databricks service principal (same application id)
                   ->  SQL warehouse
                   ->  dev.gold.taxi_daily_summary

No connection string, no personal access token, nothing in an environment
variable that would matter if it leaked. The identity IS the credential, and it
is issued at runtime and expires on its own.
"""

import logging
import os
from contextlib import contextmanager

from azure.identity import DefaultAzureCredential
from databricks import sql
from fastapi import FastAPI, HTTPException
from fastapi.responses import HTMLResponse

logging.basicConfig(level=logging.INFO)
log = logging.getLogger("taxi-api")

# The AzureDatabricks first-party application. This constant has followed us
# through the whole build - it is the resource we ask Entra for a token for.
DATABRICKS_RESOURCE = "2ff814a6-3304-4ab8-85cb-cd0e6f879c1d"

SERVER_HOSTNAME = os.environ["DATABRICKS_SERVER_HOSTNAME"]
HTTP_PATH = os.environ["DATABRICKS_HTTP_PATH"]
CATALOG = os.getenv("CATALOG", "dev")

# Cosmetic, but the page should not claim something the deployment does not do.
# The infrastructure can serve from either a SQL warehouse or an all-purpose
# cluster; the app is identical either way, so it is told which.
COMPUTE = os.getenv("SERVING_COMPUTE", "databricks")

# DefaultAzureCredential walks a chain: environment, then managed identity, then
# the Azure CLI. That is why this file runs unchanged in the Container App (where
# it finds the managed identity) and on a laptop (where it finds `az login`).
#
# The explicit client id matters: a Container App can have several identities
# assigned, and without naming one the credential has to guess.
CREDENTIAL = DefaultAzureCredential(
    managed_identity_client_id=os.getenv("AZURE_CLIENT_ID"),
    exclude_interactive_browser_credential=True,
)

app = FastAPI(title="Taxi daily summary", docs_url="/docs")


@contextmanager
def warehouse():
    """One short-lived connection per request.

    Pooling would be the obvious optimisation and is the wrong call here: a
    serverless SQL warehouse auto-stops when idle, so a pool of open connections
    is a pool of things that keep it awake and billing. Reconnecting costs
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


@app.get("/health")
def health():
    """Liveness only — deliberately does NOT touch Databricks.

    A health check that queries the warehouse would wake it on every probe, and
    the platform probes constantly. That is a genuinely expensive mistake: the
    thing meant to tell you the app is alive ends up preventing the warehouse
    from ever going to sleep.
    """
    return {"status": "ok"}


@app.get("/api/daily")
def daily(limit: int = 30):
    """Rows from the gold table, newest first."""
    query = f"""
        SELECT pickup_date, trips, avg_fare, avg_trip_minutes, total_revenue
        FROM {CATALOG}.gold.taxi_daily_summary
        ORDER BY pickup_date DESC
        LIMIT {int(limit)}
    """
    try:
        with warehouse() as conn:
            with conn.cursor() as cur:
                cur.execute(query)
                columns = [c[0] for c in cur.description]
                rows = [dict(zip(columns, r)) for r in cur.fetchall()]
    except Exception as exc:  # noqa: BLE001 - surface the cause, do not swallow it
        log.exception("query failed")
        # 503 rather than 500: the usual cause is the warehouse still starting,
        # which is transient and worth retrying. A 500 would tell a caller to
        # give up on something that will work in ten seconds.
        raise HTTPException(status_code=503, detail=str(exc)) from exc

    return {"catalog": CATALOG, "count": len(rows), "rows": rows}


@app.get("/", response_class=HTMLResponse)
def index():
    """A page, so the demo is something you can look at rather than curl."""
    try:
        data = daily(limit=30)
        rows = data["rows"]
    except HTTPException as exc:
        return HTMLResponse(
            f"<main><h1>Taxi daily summary</h1>"
            f"<p class='warn'>Warehouse not ready — {exc.detail}</p>"
            f"<p>A serverless warehouse takes a few seconds to start. Reload.</p></main>{STYLE}",
            status_code=503,
        )

    body = "".join(
        f"<tr><td>{r['pickup_date']}</td><td>{r['trips']:,}</td>"
        f"<td>{r['avg_fare']}</td><td>{r['avg_trip_minutes']}</td>"
        f"<td>{r['total_revenue']:,}</td></tr>"
        for r in rows
    )

    return HTMLResponse(f"""<main>
      <h1>Taxi daily summary</h1>
      <p>{len(rows)} days from <code>{CATALOG}.gold.taxi_daily_summary</code></p>
      <table>
        <thead><tr><th>date</th><th>trips</th><th>avg fare</th>
        <th>avg minutes</th><th>revenue</th></tr></thead>
        <tbody>{body}</tbody>
      </table>
      <p class="foot">Served from <code>{COMPUTE}</code> via managed identity.
      No credentials in this container.</p>
    </main>{STYLE}""")


STYLE = """<style>
  :root { color-scheme: light dark; }
  body { margin:0; font:14px/1.5 system-ui,-apple-system,Segoe UI,sans-serif; }
  main { max-width:52rem; margin:3rem auto; padding:0 1.5rem; }
  h1 { font-size:1.4rem; margin:0 0 .25rem; }
  table { border-collapse:collapse; width:100%; margin-top:1.25rem; }
  th,td { text-align:right; padding:.4rem .6rem; border-bottom:1px solid #8883; }
  th:first-child,td:first-child { text-align:left; }
  th { font-weight:600; opacity:.7; font-size:.85em; }
  code { background:#8882; padding:.1em .35em; border-radius:3px; }
  .foot { margin-top:2rem; opacity:.6; font-size:.9em; }
  .warn { color:#b45309; }
</style>"""
