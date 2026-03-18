# Data Collection Guide — Agent Failure Taxonomy

## Step 1 — Collect runs via the UI (ongoing)

Use the agent UI normally. After each agent response, click the thumbs-up or thumbs-down
button and add a short comment explaining why the response was good or bad.

Aim for at least **40 rated runs** before running the analysis. More is better;
60–80 gives enough negative cases to code a stable taxonomy.

---

## Step 2 — Extract raw data from PostgreSQL

### Option A: Local PostgreSQL
```bash
psql $DATABASE_URL -f extract_runs.sql --csv -o runs_raw.csv
```

### Option B: Via the cluster (kubectl)
```bash
# Copy the SQL file to the pod
kubectl cp data/extract_runs.sql <namespace>/agent-api-chart-postgresql-0:/tmp/extract_runs.sql

# Run and extract CSV
kubectl exec -n <namespace> -it agent-api-chart-postgresql-0 -- \
  psql -U <user> -d <db> --csv -f /tmp/extract_runs.sql -o /tmp/runs_raw.csv

# Copy CSV back locally
kubectl cp <namespace>/agent-api-chart-postgresql-0:/tmp/runs_raw.csv data/runs_raw.csv
```

Place the output at: `data/runs_raw.csv`

---

## Step 3 — Qualitative coding (manual, ~30 minutes)

Open `data/runs_raw.csv` in a spreadsheet app or RStudio.

For every row where `feedback_rating = 'negative'` OR `status = 'failed'`,
fill in the two coded columns using the codebook below:

### Column: `failure_category` (top-level code)

| Code | Category              | Description                                       |
|------|-----------------------|---------------------------------------------------|
| P    | Planning              | Planner produced a bad plan or no valid JSON plan |
| T    | Tool execution        | A tool call failed, timed out, or returned garbage|
| M    | Model output quality  | Response was wrong, hallucinated, or repetitive   |
| C    | Context / memory      | Wrong memories injected; context overflowed       |
| I    | Infrastructure        | Redis, DB, OOM, or network error                  |
| U    | User expectation      | Run succeeded technically but missed user intent  |

### Column: `failure_subcategory` (second-level code)

| Code  | Parent | Description                                          |
|-------|--------|------------------------------------------------------|
| P-NJ  | P      | Plan phase produced no valid JSON                    |
| P-OD  | P      | Over-decomposition: too many steps for simple task   |
| P-WT  | P      | Wrong tool selected in plan                          |
| P-LP  | P      | Planning loop / repetition (same plan twice)         |
| T-NF  | T      | Tool not found (registry mismatch)                   |
| T-TO  | T      | Tool execution timeout                               |
| T-PE  | T      | Tool output parsing error                            |
| T-EX  | T      | Tool raised exception / returned error payload       |
| M-HL  | M      | Hallucinated fact or tool name                       |
| M-RP  | M      | Repetitive / looping response                        |
| M-INC | M      | Incomplete response (cut off, partial answer)        |
| M-RF  | M      | Model refused to answer                              |
| C-MM  | C      | Memory mismatch (wrong user context injected)        |
| C-OV  | C      | Context overflow (truncated prompt)                  |
| I-OOM | I      | Out-of-memory crash on Jetson                        |
| I-NET | I      | Network / Redis connectivity error                   |
| I-DB  | I      | Database query error                                 |
| U-MI  | U      | Misunderstood intent (correct tool, wrong answer)    |
| U-IN  | U      | Insufficient depth or detail                         |

### Column: `coder_notes`

Free text. Note anything unusual — e.g., "user prompt was ambiguous",
"happened right after a Redis restart", "model was mid-response when OOM hit".

---

## Step 4 — Save coded file

Save the fully coded CSV as: `data/runs_coded.csv`
(Keep `runs_raw.csv` unchanged as the unmodified export.)

---

## Step 5 — Generate the paper

```bash
Rscript build.R
```

This reads `data/runs_coded.csv` and generates `agent-failure-taxonomy.pdf`.
