#!/usr/bin/env bash
set -euo pipefail

PROJECT_ID="bigdata2026-485103"

echo "==> Deploying Phase 3 serving views in BigQuery"
bq query \
  --project_id="${PROJECT_ID}" \
  --use_legacy_sql=false \
  < "../sql/phase3_serving_views.sql"

echo "==> Verifying created views"
bq ls --project_id="${PROJECT_ID}" "${PROJECT_ID}:nba_serving"

echo "==> Smoke test: player_profile"
bq query --project_id="${PROJECT_ID}" --use_legacy_sql=false \
  'SELECT * FROM `bigdata2026-485103.nba_serving.player_profile` LIMIT 5'

echo "==> Smoke test: player_recent_form"
bq query --project_id="${PROJECT_ID}" --use_legacy_sql=false \
  'SELECT * FROM `bigdata2026-485103.nba_serving.player_recent_form` LIMIT 5'

echo "Phase 3 deployed successfully."
