#!/usr/bin/env bash
# DaylyBread ticket monitor: pull aggregate order status from tix.africa,
# publish latest.json for the website, and push a snapshot into ERP.AI (best effort).
set -uo pipefail

EVENT_SLUG="${EVENT_SLUG:-hike_sip_grill_paint_by_dailybread_and_abujasocialconnection}"
WEBHOOK="${DAYLYBREAD_SNAPSHOT_WEBHOOK:-https://apps.erp.ai/open/v1/auto-builder/webhooks/daylybread-ticket-snapshot}"
UA="Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/125.0.0.0 Safari/537.36"

QUERY="query { filterEvents(slug: \"${EVENT_SLUG}\") { id title orders { totalCount nodes { status createdAt } } tickets { nodes { id name price status } } } }"
BODY="$(python3 -c 'import json,sys; print(json.dumps({"query": sys.argv[1]}))' "$QUERY")"

RESP="$(curl -sS --max-time 45 --retry 2 --retry-delay 3 -X POST https://core.tix.africa/graphql \
  -H 'Content-Type: application/json' \
  -H 'Accept: application/json, text/plain, */*' \
  -H 'Origin: https://tix.africa' \
  -H 'Referer: https://tix.africa/' \
  -H 'Accept-Language: en-US,en;q=0.9' \
  -H "User-Agent: ${UA}" \
  --data "$BODY")"

PAYLOAD="$(printf '%s' "$RESP" | python3 -c '
import json, sys, datetime

raw = sys.stdin.read()
try:
    data = json.loads(raw)
except Exception:
    print(json.dumps({"label": "tix fetch failed", "source": "tix.africa", "error": raw[:180], "orders": 0, "paid": 0, "expired": 0, "pending": 0}))
    sys.exit(0)

event = (data.get("data") or {}).get("filterEvents") or {}
if isinstance(event, list):
    event = event[0] if event else {}
if not isinstance(event, dict):
    event = {}

orders = event.get("orders") or {}
if not isinstance(orders, dict):
    orders = {}
nodes = orders.get("nodes") or []
if not isinstance(nodes, list):
    nodes = []

def bucket(status):
    value = str(status or "").lower()
    if value in ("complete", "completed", "paid"):
        return "paid"
    if value in ("expired", "cancelled", "canceled"):
        return "expired"
    return "pending"

counts = {"paid": 0, "expired": 0, "pending": 0}
for order in nodes:
    counts[bucket(order.get("status"))] += 1

tickets = event.get("tickets") or {}
if not isinstance(tickets, dict):
    tickets = {}
ticket_nodes = tickets.get("nodes") or []
if not isinstance(ticket_nodes, list):
    ticket_nodes = []

now = datetime.datetime.now(datetime.timezone.utc)
total = orders.get("totalCount")
if not isinstance(total, int):
    total = len(nodes)

payload = {
    "orders": total,
    "paid": counts["paid"],
    "expired": counts["expired"],
    "pending": counts["pending"],
    "ticketName": (ticket_nodes[0].get("name") if ticket_nodes else "") or "",
    "ticketPrice": (ticket_nodes[0].get("price") if ticket_nodes else 0) or 0,
    "source": "tix.africa",
    "checkedAt": now.strftime("%Y-%m-%dT%H:%M:%SZ"),
    "label": "Ticket snapshot " + now.strftime("%Y-%m-%d %H:%M UTC"),
    "date": now.strftime("%Y-%m-%d"),
}
print(json.dumps(payload))
')"

echo "snapshot: ${PAYLOAD}"

mkdir -p public
printf '%s' "$PAYLOAD" > public/latest.json
cp public/latest.json latest.json

if git rev-parse --git-dir >/dev/null 2>&1; then
  git config user.name "github-actions[bot]"
  git config user.email "github-actions[bot]@users.noreply.github.com"
  git add public/latest.json latest.json
  if git diff --cached --quiet; then
    echo "latest.json unchanged"
  else
    git commit -m "chore: refresh ticket snapshot $(date -u +%Y-%m-%dT%H:%MZ)" >/dev/null && git push >/dev/null && echo "published latest.json"
  fi
fi

echo -n "erp.ai snapshot push: "
curl -sS --max-time 45 -X POST "$WEBHOOK" -H 'Content-Type: application/json' --data "$PAYLOAD" | head -c 220
echo
