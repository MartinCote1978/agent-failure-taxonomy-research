-- =============================================================================
-- Agent Failure Taxonomy Research — Data Extraction Query
-- Run against the agent-api-server PostgreSQL database
--
-- Usage (local):
--   psql $DATABASE_URL -f extract_runs.sql --csv -o runs_raw.csv
--
-- Usage (on cluster via kubectl):
--   kubectl exec -n <ns> -it memory-api-chart-postgresql-0 -- \
--     psql -U <user> -d <db> -f /tmp/extract_runs.sql --csv -o /tmp/runs_raw.csv
--
-- Then copy the CSV into this data/ folder and rename to runs_raw.csv
-- =============================================================================

SELECT
  r.id                                                        AS run_id,
  r.assignment_id,
  a.title                                                     AS assignment_title,
  r.created_at,
  r.status,
  r.error,
  r.model_name,

  -- Duration in milliseconds
  CASE
    WHEN r.ended_at IS NOT NULL AND r.started_at IS NOT NULL
      THEN ROUND(EXTRACT(EPOCH FROM (r.ended_at - r.started_at)) * 1000)
    ELSE NULL
  END                                                         AS duration_ms,

  -- Token usage
  r.prompt_tokens,
  r.completion_tokens,
  r.total_tokens,
  r.llm_calls,

  -- Plan metadata (Phase 1 output)
  r.plan->>'goal'                                             AS plan_goal,
  COALESCE(
    jsonb_array_length(r.plan->'steps'), 0
  )                                                           AS plan_step_count,

  -- User's original prompt (trigger message)
  m.content                                                   AS user_message,

  -- Tool call aggregates
  COALESCE(tc_agg.tool_call_count, 0)                        AS tool_call_count,
  COALESCE(tc_agg.tools_used, '')                            AS tools_used,
  COALESCE(tc_agg.failed_tool_count, 0)                      AS failed_tool_count,

  -- Run step count
  COALESCE(rs_agg.step_count, 0)                             AS step_count,

  -- User feedback
  f.rating                                                    AS feedback_rating,
  f.comment                                                   AS feedback_comment

FROM "Run" r
JOIN "Assignment"  a      ON r.assignment_id      = a.id
LEFT JOIN "Message"       m      ON r.trigger_message_id  = m.id

LEFT JOIN (
  SELECT
    run_id,
    COUNT(*)                                              AS tool_call_count,
    STRING_AGG(DISTINCT tool_name, '; ' ORDER BY tool_name) AS tools_used,
    COUNT(*) FILTER (WHERE status = 'failed')            AS failed_tool_count
  FROM "ToolCall"
  GROUP BY run_id
) tc_agg ON r.id = tc_agg.run_id

LEFT JOIN (
  SELECT run_id, COUNT(*) AS step_count
  FROM "RunStep"
  GROUP BY run_id
) rs_agg ON r.id = rs_agg.run_id

LEFT JOIN "RunFeedback" f ON r.id = f.run_id

WHERE r.status IN ('completed', 'failed')

ORDER BY r.created_at DESC;
