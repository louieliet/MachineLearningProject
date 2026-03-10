#!/usr/bin/env bash
set -euo pipefail

PROJECT_ID="bigdata2026-485103"

echo "==> Deploying Phase 4 advanced serving views"
bq query \
  --project_id="${PROJECT_ID}" \
  --use_legacy_sql=false \
  < "../sql/phase4_advanced_serving_views.sql"

echo "==> Verifying new views in nba_serving"
bq ls --project_id="${PROJECT_ID}" "${PROJECT_ID}:nba_serving"

echo "==> Smoke test: player_advanced_summary"
bq query --project_id="${PROJECT_ID}" --use_legacy_sql=false \
  'SELECT personid, firstname, lastname, season_avg_points, last10_avg_points, true_shooting_pct
   FROM `bigdata2026-485103.nba_serving.player_advanced_summary`
   ORDER BY season_avg_points DESC
   LIMIT 5'

echo "==> Smoke test: team_current_overview"
bq query --project_id="${PROJECT_ID}" --use_legacy_sql=false \
  'SELECT teamname, wins_overall, losses_overall, win_pct, net_rating_proxy
   FROM `bigdata2026-485103.nba_serving.team_current_overview`
   ORDER BY win_pct DESC
   LIMIT 10'

echo "==> Smoke test: team_player_leaders (points leaders)"
bq query --project_id="${PROJECT_ID}" --use_legacy_sql=false \
  'SELECT teamname, firstname, lastname, avg_points
   FROM `bigdata2026-485103.nba_serving.team_player_leaders`
   WHERE rank_points = 1
   ORDER BY avg_points DESC
   LIMIT 10'

echo "Phase 4 advanced serving deployed successfully."
