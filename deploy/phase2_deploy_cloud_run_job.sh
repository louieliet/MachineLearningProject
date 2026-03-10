#!/usr/bin/env bash
set -euo pipefail

PROJECT_ID="bigdata2026-485103"
REGION="us-west1"
AR_REPO="nba-jobs"
IMAGE_NAME="player-enrichment"
JOB_NAME="nba-player-enrichment-job"
SCHEDULER_JOB_NAME="nba-player-enrichment-scheduler"
CRON_SCHEDULE="0 */6 * * *"
TIME_ZONE="America/Mexico_City"

CURATED_DATASET="nba_curated"
ENRICHMENT_DATASET="nba_enrichment"
SEASON="2025-2026"
BATCH_SIZE="100"
REQUEST_TIMEOUT="8"
INSERT_BATCH_SIZE="20"
LOG_EVERY="5"
SKIP_STATS_API="--skip-stats-api"

JOB_SA_NAME="nba-enrichment-runner"
SCHED_SA_NAME="nba-enrichment-scheduler"
JOB_SA_EMAIL="${JOB_SA_NAME}@${PROJECT_ID}.iam.gserviceaccount.com"
SCHED_SA_EMAIL="${SCHED_SA_NAME}@${PROJECT_ID}.iam.gserviceaccount.com"

IMAGE_URI="${REGION}-docker.pkg.dev/${PROJECT_ID}/${AR_REPO}/${IMAGE_NAME}:latest"

echo "==> Set project"
gcloud config set project "${PROJECT_ID}" >/dev/null

echo "==> Enable APIs"
gcloud services enable \
  run.googleapis.com \
  artifactregistry.googleapis.com \
  cloudbuild.googleapis.com \
  cloudscheduler.googleapis.com \
  bigquery.googleapis.com \
  iam.googleapis.com

echo "==> Create Artifact Registry (if missing)"
gcloud artifacts repositories create "${AR_REPO}" \
  --repository-format=docker \
  --location="${REGION}" \
  --description="Repo for NBA enrichment jobs" || true

echo "==> Build container image"
BUILD_DIR="$(mktemp -d)"
cp ../pipeline/Dockerfile.step2 "${BUILD_DIR}/Dockerfile"
cp ../pipeline/step2_scrape_enrich_players.py "${BUILD_DIR}/step2_scrape_enrich_players.py"
cp ../pipeline/requirements_step2.txt "${BUILD_DIR}/requirements_step2.txt"
gcloud builds submit "${BUILD_DIR}" \
  --project="${PROJECT_ID}" \
  --tag "${IMAGE_URI}"
rm -rf "${BUILD_DIR}"

echo "==> Create service accounts (if missing)"
gcloud iam service-accounts create "${JOB_SA_NAME}" \
  --display-name="NBA Enrichment Runner SA" || true
gcloud iam service-accounts create "${SCHED_SA_NAME}" \
  --display-name="NBA Enrichment Scheduler SA" || true

echo "==> Grant IAM roles to job service account"
gcloud projects add-iam-policy-binding "${PROJECT_ID}" \
  --member="serviceAccount:${JOB_SA_EMAIL}" \
  --role="roles/bigquery.dataEditor" >/dev/null
gcloud projects add-iam-policy-binding "${PROJECT_ID}" \
  --member="serviceAccount:${JOB_SA_EMAIL}" \
  --role="roles/bigquery.jobUser" >/dev/null

echo "==> Grant IAM roles to scheduler service account"
gcloud projects add-iam-policy-binding "${PROJECT_ID}" \
  --member="serviceAccount:${SCHED_SA_EMAIL}" \
  --role="roles/run.invoker" >/dev/null
gcloud projects add-iam-policy-binding "${PROJECT_ID}" \
  --member="serviceAccount:${SCHED_SA_EMAIL}" \
  --role="roles/cloudscheduler.serviceAgent" >/dev/null || true

echo "==> Create or update Cloud Run Job"
if gcloud run jobs describe "${JOB_NAME}" --region="${REGION}" >/dev/null 2>&1; then
  gcloud run jobs update "${JOB_NAME}" \
    --region="${REGION}" \
    --image="${IMAGE_URI}" \
    --service-account="${JOB_SA_EMAIL}" \
    --task-timeout=3600s \
    --max-retries=1 \
    --command=python \
    --args=-u \
    --args=/app/step2_scrape_enrich_players.py \
    --args=--project-id \
    --args="${PROJECT_ID}" \
    --args=--curated-dataset \
    --args="${CURATED_DATASET}" \
    --args=--enrichment-dataset \
    --args="${ENRICHMENT_DATASET}" \
    --args=--season \
    --args="${SEASON}" \
    --args=--batch-size \
    --args="${BATCH_SIZE}" \
    --args=--request-timeout \
    --args="${REQUEST_TIMEOUT}" \
    --args=--insert-batch-size \
    --args="${INSERT_BATCH_SIZE}" \
    --args=--log-every \
    --args="${LOG_EVERY}" \
    --args="${SKIP_STATS_API}"
else
  gcloud run jobs create "${JOB_NAME}" \
    --region="${REGION}" \
    --image="${IMAGE_URI}" \
    --service-account="${JOB_SA_EMAIL}" \
    --task-timeout=3600s \
    --max-retries=1 \
    --command=python \
    --args=-u \
    --args=/app/step2_scrape_enrich_players.py \
    --args=--project-id \
    --args="${PROJECT_ID}" \
    --args=--curated-dataset \
    --args="${CURATED_DATASET}" \
    --args=--enrichment-dataset \
    --args="${ENRICHMENT_DATASET}" \
    --args=--season \
    --args="${SEASON}" \
    --args=--batch-size \
    --args="${BATCH_SIZE}" \
    --args=--request-timeout \
    --args="${REQUEST_TIMEOUT}" \
    --args=--insert-batch-size \
    --args="${INSERT_BATCH_SIZE}" \
    --args=--log-every \
    --args="${LOG_EVERY}" \
    --args="${SKIP_STATS_API}"
fi

echo "==> Create or update Cloud Scheduler job"
SCHED_URI="https://${REGION}-run.googleapis.com/apis/run.googleapis.com/v1/namespaces/${PROJECT_ID}/jobs/${JOB_NAME}:run"

if gcloud scheduler jobs describe "${SCHEDULER_JOB_NAME}" --location="${REGION}" >/dev/null 2>&1; then
  gcloud scheduler jobs update http "${SCHEDULER_JOB_NAME}" \
    --location="${REGION}" \
    --schedule="${CRON_SCHEDULE}" \
    --time-zone="${TIME_ZONE}" \
    --uri="${SCHED_URI}" \
    --http-method=POST \
    --oauth-service-account-email="${SCHED_SA_EMAIL}" \
    --oauth-token-scope="https://www.googleapis.com/auth/cloud-platform"
else
  gcloud scheduler jobs create http "${SCHEDULER_JOB_NAME}" \
    --location="${REGION}" \
    --schedule="${CRON_SCHEDULE}" \
    --time-zone="${TIME_ZONE}" \
    --uri="${SCHED_URI}" \
    --http-method=POST \
    --oauth-service-account-email="${SCHED_SA_EMAIL}" \
    --oauth-token-scope="https://www.googleapis.com/auth/cloud-platform"
fi

echo "==> Run job now (smoke test)"
gcloud run jobs execute "${JOB_NAME}" --region="${REGION}" --wait

echo "================================================="
echo "Fase 2 lista:"
echo "Cloud Run Job: ${JOB_NAME}"
echo "Scheduler:     ${SCHEDULER_JOB_NAME}"
echo "Image:         ${IMAGE_URI}"
echo "================================================="
