#!/usr/bin/env bash
# collect_metrics.sh — Agent Failure Taxonomy Research
#
# Does two things in one pass:
#
#   PART A — Performance metrics (planner latency, tool round-trip, memory
#             retrieval, distillation pipeline, chatbot stats) written to:
#               data/performance_metrics_YYYY-MM-DD_HH-MM-SS.csv  (kept forever)
#               data/performance_metrics.csv                       (latest alias)
#
#   PART B — Incremental run extraction via data/extract_runs.sql written to:
#               data/runs_raw_YYYY-MM-DD_HH-MM-SS.csv  (this batch only, kept forever)
#
#             Incremental logic:
#               - data/.lastrun stores the created_at of the newest row from the
#                 last extraction; only runs newer than that are fetched
#
#             The Rmd loads ALL runs_raw_*.csv files from data/ and combines
#             them automatically — no merging or cumulative file needed.
#
# Usage:
#   chmod +x collect_metrics.sh
#   ./collect_metrics.sh [--namespace <ns>] [--log-lines <n>]
#
# Flags:
#   --namespace    Kubernetes namespace (default: default)
#   --log-lines    Tail lines to scan per pod for log-based metrics (default: 1000)

set -euo pipefail

# ── Defaults ────────────────────────────────────────────────────────────────
NAMESPACE="default"
LOG_LINES=1000
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
DATETIME=$(date +%Y-%m-%d_%H-%M-%S)

PERF_DATED="$SCRIPT_DIR/data/performance_metrics_${DATETIME}.csv"
PERF_LATEST="$SCRIPT_DIR/data/performance_metrics.csv"
RUNS_DATED="$SCRIPT_DIR/data/runs_raw_${DATETIME}.csv"
LASTRUN_FILE="$SCRIPT_DIR/data/.lastrun"

# ── Argument parsing ─────────────────────────────────────────────────────────
while [[ $# -gt 0 ]]; do
  case $1 in
    --namespace)    NAMESPACE="$2"; shift 2 ;;
    --log-lines)    LOG_LINES="$2";  shift 2 ;;
    *) echo "Unknown flag: $1"; exit 1       ;;
  esac
done

# ── Colors / logging helpers ─────────────────────────────────────────────────
GREEN='\033[0;32m'; YELLOW='\033[1;33m'; RED='\033[0;31m'; CYAN='\033[0;36m'
BLUE='\033[0;34m'; BOLD='\033[1m'; NC='\033[0m'
info()  { echo -e "${GREEN}[INFO]${NC}  $1"; }
warn()  { echo -e "${YELLOW}[WARN]${NC}  $1"; }
error() { echo -e "${RED}[ERROR]${NC} $1"; }
next()  { echo -e "${BLUE}[NEXT]${NC}  $1"; }
header(){ echo -e "\n${CYAN}── $1 ──${NC}"; }
banner(){ echo -e "\n${BOLD}${CYAN}════ $1 ════${NC}"; }

# ── Dependency check ─────────────────────────────────────────────────────────
header "Checking dependencies"
MISSING=()
for cmd in kubectl jq awk sed bc python3 column; do
  if command -v "$cmd" &>/dev/null; then
    info "  $cmd ✓"
  else
    warn "  $cmd ✗ (missing)"
    MISSING+=("$cmd")
  fi
done
if [[ ${#MISSING[@]} -gt 0 ]]; then
  error "Missing required tools: ${MISSING[*]}"
  exit 1
fi

mkdir -p "$SCRIPT_DIR/data"

# ── Helper: run psql in a pod, return trimmed result or "N/A" ────────────────
psql_query() {
  local POD="$1" USER="$2" DB="$3" QUERY="$4" PASSWORD="${5:-}"
  if [[ -n "$PASSWORD" ]]; then
    kubectl exec -n "$NAMESPACE" "$POD" -- \
      env PGPASSWORD="$PASSWORD" psql -U "$USER" -d "$DB" -tAc "$QUERY" 2>/dev/null \
      | tr -d ' \n\r' \
      | grep -v '^$' \
      || echo "N/A"
  else
    kubectl exec -n "$NAMESPACE" "$POD" -- \
      psql -U "$USER" -d "$DB" -tAc "$QUERY" 2>/dev/null \
      | tr -d ' \n\r' \
      | grep -v '^$' \
      || echo "N/A"
  fi
}

# ── Helper: p50 / p95 from newline-separated numbers ─────────────────────────
percentile() {
  local DATA="$1" PCT="$2"
  echo "$DATA" | sort -n | awk -v p="$PCT" '
    BEGIN { n = 0 }
    { lines[n++] = $1 }
    END {
      if (n == 0) { print "N/A"; exit }
      idx = int((p / 100) * n + 0.5)
      if (idx < 1)  idx = 1
      if (idx > n)  idx = n
      print lines[idx - 1]
    }'
}

# ════════════════════════════════════════════════════════════════════════════
# PART A — PERFORMANCE METRICS
# ════════════════════════════════════════════════════════════════════════════
banner "PART A — Performance Metrics  (${DATETIME})"

# ── 1/5  Tool-call round-trip ────────────────────────────────────────────────
header "1/5  Tool-call round-trip  [agent-api-chart-postgresql-0]"
TOOL_AVG=$(psql_query \
  "agent-api-chart-postgresql-0" "ps_agent" "ps_agent_db" \
  'SELECT COALESCE(ROUND(AVG(duration_ms))::text, '"'"'N/A'"'"')
   FROM "ToolCall"
   WHERE duration_ms IS NOT NULL;')
info "Avg tool-call round-trip: ${TOOL_AVG} ms"

# ── 2/5  Distillation pipeline (log pairs) ──────────────────────────────────
header "2/5  Distillation pipeline  [memory-distiller-chart pod logs, last ${LOG_LINES} lines]"
DISTILL_TIMES=$(kubectl logs -n "$NAMESPACE" \
  -l "app.kubernetes.io/name=memory-distiller-chart" -c memory-distiller-chart \
  --tail="$LOG_LINES" 2>/dev/null \
  | grep ' - main - INFO - ' \
  | grep -E 'Accepted distillation request for source|Distillation complete for source' \
  | python3 -c "
import sys, re
from datetime import datetime

starts = {}
durations = []
pat = re.compile(r'^(\d{4}-\d{2}-\d{2} \d{2}:\d{2}:\d{2},\d+) - main - INFO - (.+)$')
for line in sys.stdin:
    m = pat.match(line.strip())
    if not m: continue
    ts_str, msg = m.group(1), m.group(2)
    ts = datetime.strptime(ts_str, '%Y-%m-%d %H:%M:%S,%f').timestamp()
    accept   = re.search(r'Accepted distillation request for source ([a-f0-9-]+)', msg)
    complete = re.search(r'Distillation complete for source ([a-f0-9-]+)', msg)
    if accept:
        starts[accept.group(1)] = ts
    elif complete:
        uid = complete.group(1)
        if uid in starts:
            durations.append(int((ts - starts[uid]) * 1000))
            del starts[uid]
for d in durations:
    print(d)
" 2>/dev/null \
  || true)

if [[ -n "$DISTILL_TIMES" ]]; then
  DISTILL_P50=$(percentile "$DISTILL_TIMES" 50)
  DISTILL_P95=$(percentile "$DISTILL_TIMES" 95)
  DISTILL_COUNT=$(echo "$DISTILL_TIMES" | wc -l | tr -d ' ')
  DISTILL_P50_S=$(echo "scale=1; $DISTILL_P50 / 1000" | bc)
  DISTILL_P95_S=$(echo "scale=1; $DISTILL_P95 / 1000" | bc)
  DISTILL="${DISTILL_P50_S} / ${DISTILL_P95_S}"
  info "Distillation p50/p95: ${DISTILL} s  (n=${DISTILL_COUNT})"
else
  DISTILL="N/A / N/A"
  warn "No distillation log pairs found — try --log-lines 5000"
fi

# ── 3/5  Planner latency ─────────────────────────────────────────────────────
header "3/5  Planner latency  [agent-api-chart pod logs, last ${LOG_LINES} lines]"
PLANNER_TIMES=$(kubectl logs -n "$NAMESPACE" \
  -l "app.kubernetes.io/name=agent-api-chart" -c agent-api-chart \
  --tail="$LOG_LINES" 2>/dev/null \
  | grep '^{' \
  | grep '"component":"planner"' \
  | jq -r 'select(.duration_ms != null) | .duration_ms' 2>/dev/null \
  || true)

if [[ -n "$PLANNER_TIMES" ]]; then
  PLANNER_P50=$(percentile "$PLANNER_TIMES" 50)
  PLANNER_P95=$(percentile "$PLANNER_TIMES" 95)
  PLANNER_COUNT=$(echo "$PLANNER_TIMES" | wc -l | tr -d ' ')
  PLANNER_VAL="${PLANNER_P50} / ${PLANNER_P95}"
  info "Planner latency p50/p95: ${PLANNER_VAL} ms  (n=${PLANNER_COUNT})"
else
  PLANNER_VAL="N/A"
  warn "No planner log entries found — try --log-lines 5000"
fi

# ── 4/5  Memory retrieval ────────────────────────────────────────────────────
header "4/5  Memory retrieval  [memory-api-chart pod logs, last ${LOG_LINES} lines]"
RETRIEVAL_TIMES=$(kubectl logs -n "$NAMESPACE" \
  -l "app.kubernetes.io/name=memory-api-chart" -c memory-api-chart \
  --tail="$LOG_LINES" 2>/dev/null \
  | grep '^{' \
  | jq -r 'select(.component == "assignment-controller" and .msg == "Memories retrieved" and .duration_ms != null) | .duration_ms' 2>/dev/null \
  || true)

if [[ -n "$RETRIEVAL_TIMES" ]]; then
  MEM_P50=$(percentile "$RETRIEVAL_TIMES" 50)
  MEM_P95=$(percentile "$RETRIEVAL_TIMES" 95)
  MEM_COUNT=$(echo "$RETRIEVAL_TIMES" | wc -l | tr -d ' ')
  MEM_VAL="${MEM_P50} / ${MEM_P95}"
  info "Memory retrieval p50/p95: ${MEM_VAL} ms  (n=${MEM_COUNT})"
else
  MEM_VAL="N/A"
  warn "No retrieval log entries found — try --log-lines 5000"
fi

# ── 5/5  Chatbot ─────────────────────────────────────────────────────────────
header "5/5  Chatbot  [chatbot-api-chart-postgresql-0 + pod logs, last ${LOG_LINES} lines]"
CHATBOT_TOKENS=$(psql_query \
  "chatbot-api-chart-postgresql-0" "ps_chatbot" "ps_chatbot_db" \
  'SELECT COALESCE(ROUND(AVG(prompt_tokens + completion_tokens))::text, '"'"'N/A'"'"')
   FROM "Message"
   WHERE role = '"'"'assistant'"'"' AND (prompt_tokens + completion_tokens) > 0;' \
  "admin")
info "Chatbot avg tokens per response: ${CHATBOT_TOKENS} tokens"

CHATBOT_LATENCY_TIMES=$(kubectl logs -n "$NAMESPACE" \
  -l "app.kubernetes.io/name=chatbot-api-chart" -c chatbot-api-chart \
  --tail="$LOG_LINES" 2>/dev/null \
  | grep '^{' \
  | grep 'chat-stream-controller' \
  | python3 -c "
import sys, json
from datetime import datetime
starts = {}
for line in sys.stdin:
    try: obj = json.loads(line)
    except: continue
    cid, msg, t = obj.get('chat_id'), obj.get('msg'), obj.get('time')
    if not (cid and msg and t): continue
    ts = datetime.fromisoformat(t.replace('Z','+00:00')).timestamp()
    if msg == 'Starting Ollama stream':
        starts[cid] = ts
    elif msg == 'Assistant message saved' and cid in starts:
        print(int((ts - starts[cid]) * 1000))
        del starts[cid]
" 2>/dev/null \
  || true)

if [[ -n "$CHATBOT_LATENCY_TIMES" ]]; then
  CHATBOT_P50=$(percentile "$CHATBOT_LATENCY_TIMES" 50)
  CHATBOT_P95=$(percentile "$CHATBOT_LATENCY_TIMES" 95)
  CHATBOT_COUNT=$(echo "$CHATBOT_LATENCY_TIMES" | wc -l | tr -d ' ')
  CHATBOT_LAT="${CHATBOT_P50} / ${CHATBOT_P95}"
  info "Chatbot response latency p50/p95: ${CHATBOT_LAT} ms  (n=${CHATBOT_COUNT})"
else
  CHATBOT_LAT="N/A"
  warn "No chatbot log pairs found — try --log-lines 5000"
fi

# ── Write performance CSV (dated + latest) ───────────────────────────────────
header "Writing performance CSVs"
cat > "$PERF_DATED" << EOF
service,metric,value,unit,source
Agent,Avg. planner latency (Qwen3.5:2b),${PLANNER_VAL},ms,pod logs — agent-api-chart
Agent,Avg. tool-call round-trip,${TOOL_AVG},ms,DB ToolCall.duration_ms
Agent,Memory retrieval p50 / p95,${MEM_VAL},ms,pod logs — memory-api-chart
Agent,Distillation pipeline p50 / p95,${DISTILL},s,pod logs — memory-distiller-chart
Chatbot,Avg. response latency (w/ thinking),${CHATBOT_LAT},ms,pod logs — chatbot-api-chart
Chatbot,Avg. tokens per response,${CHATBOT_TOKENS},tokens,DB Message.(prompt+completion)_tokens
EOF
cp "$PERF_DATED" "$PERF_LATEST"
info "✅  performance_metrics_${DATETIME}.csv  →  performance_metrics.csv"
echo ""
column -t -s',' "$PERF_DATED"

# ════════════════════════════════════════════════════════════════════════════
# PART B — INCREMENTAL RUN EXTRACTION
# ════════════════════════════════════════════════════════════════════════════
banner "PART B — Run Extraction  (${DATETIME})"

SQL_FILE="$SCRIPT_DIR/data/extract_runs.sql"
if [[ ! -f "$SQL_FILE" ]]; then
  error "SQL file not found: $SQL_FILE"
  exit 1
fi

# ── Determine cutoff timestamp ───────────────────────────────────────────────
header "6/6  Extracting runs  [agent-api-chart-postgresql-0]"

CUTOFF=""
if [[ -f "$LASTRUN_FILE" ]]; then
  CUTOFF=$(cat "$LASTRUN_FILE" | tr -d '\n\r')
  info "Last extraction: ${CUTOFF}"
  info "Fetching only runs created after: ${CUTOFF}"
else
  info "No prior extraction found (.lastrun missing) — fetching all runs"
fi

# ── Build runtime SQL (inject cutoff into a temp copy) ──────────────────────
if [[ -n "$CUTOFF" ]]; then
  sed "s/WHERE r.status IN ('completed', 'failed')/WHERE r.status IN ('completed', 'failed')\n  AND r.created_at > '${CUTOFF}'/" \
    "$SQL_FILE" > /tmp/extract_runs_current.sql
  info "SQL cutoff filter applied: created_at > '${CUTOFF}'"
else
  cp "$SQL_FILE" /tmp/extract_runs_current.sql
  info "No cutoff filter — full extraction"
fi

# ── Copy SQL to pod ──────────────────────────────────────────────────────────
info "Copying SQL to pod..."
kubectl cp /tmp/extract_runs_current.sql \
  "$NAMESPACE/agent-api-chart-postgresql-0:/tmp/extract_runs.sql"

# ── Run SQL inside pod → /tmp/runs_raw_export.csv ────────────────────────────
info "Running SQL query..."
kubectl exec -n "$NAMESPACE" agent-api-chart-postgresql-0 -- \
  env PGPASSWORD=admin \
  psql -U ps_agent -d ps_agent_db --csv \
  -f /tmp/extract_runs.sql \
  -o /tmp/runs_raw_export.csv

# ── Copy result back ─────────────────────────────────────────────────────────
info "Copying results back..."
kubectl cp \
  "$NAMESPACE/agent-api-chart-postgresql-0:/tmp/runs_raw_export.csv" \
  "$RUNS_DATED"

# ── Append classification columns (failure_category / subcategory / notes) ───
info "Adding classification columns..."
python3 - "$RUNS_DATED" << 'PYEOF'
import csv, sys
path = sys.argv[1]
with open(path, newline='') as f:
    rows = list(csv.reader(f))
if not rows:
    sys.exit(0)
new_cols = ['failure_category', 'failure_subcategory', 'coder_notes']
if new_cols[0] in rows[0]:
    sys.exit(0)  # already present — idempotent
rows[0] += new_cols
for row in rows[1:]:
    row += ['', '', '']
with open(path, 'w', newline='') as f:
    csv.writer(f).writerows(rows)
PYEOF

# ── Count new rows (header = 1 line) ────────────────────────────────────────
NEW_ROWS=$(awk 'NR>1 { count++ } END { print count+0 }' "$RUNS_DATED")

# ── Update .lastrun ──────────────────────────────────────────────────────────
if [[ "$NEW_ROWS" -gt 0 ]]; then
  info "✅  ${NEW_ROWS} new rows extracted → runs_raw_${DATETIME}.csv"
  # SQL orders DESC so first data row is the newest — use Python for proper CSV parsing
  NEW_MAX_TS=$(python3 - "$RUNS_DATED" <<'PYEOF'
import csv, sys
with open(sys.argv[1]) as f:
    rows = list(csv.DictReader(f))
# rows are DESC; pick first non-empty created_at
for row in rows:
    ts = row.get('created_at', '').strip()
    if ts:
        print(ts)
        break
PYEOF
)
  if [[ -n "$NEW_MAX_TS" ]]; then
    echo "$NEW_MAX_TS" > "$LASTRUN_FILE"
    info "Last run timestamp saved: ${NEW_MAX_TS}"
  fi
else
  info "No new runs found since last extraction — .lastrun unchanged"
fi

# ── Summary stats ─────────────────────────────────────────────────────────────
echo ""
info "This batch (${NEW_ROWS} rows):"
if [[ "$NEW_ROWS" -gt 0 ]]; then
  awk -F',' '
  NR == 1 { next }
  {
    gsub(/"/, "", $5); gsub(/"/, "", $19)
    total++
    if ($5 == "failed")    failed++
    if ($5 == "completed") completed++
    if ($19 != "")         rated++
    if ($19 == "negative") negative++
    if ($19 == "positive") positive++
  }
  END {
    printf "  completed  : %d   failed   : %d\n", completed, failed
    printf "  rated      : %d   unrated  : %d\n", rated, (total - rated)
    printf "  positive   : %d   negative : %d\n", positive, negative
  }' "$RUNS_DATED"
fi

# ── Next-steps reminder ───────────────────────────────────────────────────────
echo ""
echo -e "${BOLD}Next steps for failure coding:${NC}"
if [[ "$NEW_ROWS" -gt 0 ]]; then
  next "${NEW_ROWS} new rows → data/runs_raw_${DATETIME}.csv"
  next ""
  next "Open data/runs_raw_${DATETIME}.csv and fill in the three coding columns"
  next "for negative-feedback and failed rows only:"
  next "  failure_category   — P / T / M / C / I / U"
  next "  failure_subcategory — e.g. P-OD, T-NF, M-HL …"
  next "  coder_notes        — optional free-text notes"
  next ""
  next "Leave those columns blank for positive / no-feedback rows."
  next "Save the file in-place (do NOT rename it)."
  next ""
  next "The Rmd loads ALL runs_raw_*.csv files automatically and combines"
  next "them into one dataset — no merging or copying needed."
  next ""
  next "Then Knit  agent-failure-taxonomy.Rmd  in RStudio."
else
  next "No new rows to code — nothing to do until more agent runs are completed."
  next "Then Knit  agent-failure-taxonomy.Rmd  in RStudio to refresh analysis."
fi
echo ""
info "✅  Done.  Dated file preserved; .lastrun updated."
