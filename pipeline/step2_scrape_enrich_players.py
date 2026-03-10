#!/usr/bin/env python3
import argparse
import datetime as dt
import json
import re
import time
from collections import Counter
from typing import Dict, List, Optional

import requests
from bs4 import BeautifulSoup
from google.cloud import bigquery
from google.oauth2 import service_account


NBA_STATS_HEADERS = {
    "User-Agent": (
        "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) "
        "AppleWebKit/537.36 (KHTML, like Gecko) "
        "Chrome/122.0.0.0 Safari/537.36"
    ),
    "Referer": "https://www.nba.com/",
    "Origin": "https://www.nba.com",
    "Accept": "application/json, text/plain, */*",
}


NULL_LIKE_SQL = """
birthdate IS NULL OR TRIM(CAST(birthdate AS STRING)) = '' OR
school IS NULL OR TRIM(CAST(school AS STRING)) = '' OR
country IS NULL OR TRIM(CAST(country AS STRING)) = '' OR
heightinches IS NULL OR
bodyweightlbs IS NULL OR
draftyear IS NULL OR
draftround IS NULL OR
draftnumber IS NULL
"""

TARGET_ENRICH_FIELDS = [
    "birthdate",
    "school",
    "country",
    "heightinches",
    "bodyweightlbs",
    "draftyear",
    "draftround",
    "draftnumber",
]


def parse_height_to_inches(height_value: Optional[str]) -> Optional[float]:
    if not height_value:
        return None

    value = height_value.strip()
    value = value.replace('"', "")
    match = re.match(r"^\s*(\d+)\s*[-']\s*(\d+)\s*$", value)
    if not match:
        return None

    feet = int(match.group(1))
    inches = int(match.group(2))
    return float(feet * 12 + inches)


def parse_weight_to_lbs(weight_value: Optional[str]) -> Optional[float]:
    if not weight_value:
        return None

    value = weight_value.strip().lower()
    if "kg" in value:
        number = re.sub(r"[^0-9.]", "", value)
        if number:
            return round(float(number) * 2.20462262, 2)

    number = re.sub(r"[^0-9.]", "", value)
    return float(number) if number else None


def parse_height_any_to_inches(raw_value: object) -> Optional[float]:
    if raw_value is None:
        return None
    if isinstance(raw_value, (int, float)):
        value = float(raw_value)
        if value <= 0:
            return None
        if value > 100:
            return round(value / 2.54, 2)
        if value <= 3.0:
            return round(value * 39.3701, 2)
        return round(value, 2)

    value = str(raw_value).strip().lower()
    if not value:
        return None

    if "cm" in value:
        number = re.sub(r"[^0-9.]", "", value)
        return round(float(number) / 2.54, 2) if number else None
    if "m" in value and "cm" not in value:
        number = re.sub(r"[^0-9.]", "", value)
        return round(float(number) * 39.3701, 2) if number else None
    if "in" in value:
        number = re.sub(r"[^0-9.]", "", value)
        return float(number) if number else None

    parsed = parse_height_to_inches(value)
    if parsed is not None:
        return parsed

    number = re.sub(r"[^0-9.]", "", value)
    if not number:
        return None
    value_num = float(number)
    if value_num > 100:
        return round(value_num / 2.54, 2)
    if value_num <= 3.0:
        return round(value_num * 39.3701, 2)
    return round(value_num, 2)


def clean_nullable_text(raw_value: object) -> Optional[str]:
    if raw_value is None:
        return None
    value = str(raw_value).strip()
    if not value:
        return None
    lowered = value.lower()
    if lowered in {"null", "none", "na", "n/a", "nan", "undefined", "--"}:
        return None
    return value


def parse_draft_components(
    draft_year_raw: object,
    draft_round_raw: object,
    draft_number_raw: object,
    draft_text_raw: object = None,
) -> Dict[str, Optional[str]]:
    def digits_or_none(raw: object, min_len: int = 1, max_len: int = 4) -> Optional[str]:
        value = clean_nullable_text(raw)
        if value is None:
            return None
        digits = re.sub(r"[^0-9]", "", value)
        if min_len <= len(digits) <= max_len:
            return digits
        return None

    year = digits_or_none(draft_year_raw, min_len=4, max_len=4)
    rnd = digits_or_none(draft_round_raw, min_len=1, max_len=2)
    pick = digits_or_none(draft_number_raw, min_len=1, max_len=3)

    draft_text = clean_nullable_text(draft_text_raw)
    draft_text_lower = draft_text.lower() if draft_text else ""
    if draft_text and "undrafted" in draft_text_lower:
        return {
            "draftyear": None,
            "draftround": None,
            "draftnumber": None,
        }

    if year and rnd and pick:
        return {
            "draftyear": year,
            "draftround": rnd,
            "draftnumber": pick,
        }

    if draft_text:
        year_match = re.search(r"\b((?:19|20)\d{2})\b", draft_text)
        round_match = re.search(r"\bR(?:ound)?\s*([0-9]{1,2})\b", draft_text, flags=re.IGNORECASE)
        if not round_match:
            round_match = re.search(r"\bRound\s*([0-9]{1,2})\b", draft_text, flags=re.IGNORECASE)
        pick_match = re.search(r"\bPick\s*([0-9]{1,3})\b", draft_text, flags=re.IGNORECASE)
        if not pick_match:
            pick_match = re.search(r"\bNo\.?\s*([0-9]{1,3})\b", draft_text, flags=re.IGNORECASE)
        if not pick_match:
            pick_match = re.search(
                r"\b([0-9]{1,3})(?:st|nd|rd|th)\s+overall\b",
                draft_text,
                flags=re.IGNORECASE,
            )
        if not pick_match:
            pick_match = re.search(
                r"\bR(?:ound)?\s*[0-9]{1,2}\s*P(?:ick)?\s*([0-9]{1,3})\b",
                draft_text,
                flags=re.IGNORECASE,
            )

        year = year or (year_match.group(1) if year_match else None)
        rnd = rnd or (round_match.group(1) if round_match else None)
        pick = pick or (pick_match.group(1) if pick_match else None)

    return {
        "draftyear": year,
        "draftround": rnd,
        "draftnumber": pick,
    }


def _collect_values_by_key(node: object, wanted_keys: set, out: List[object]) -> None:
    def normalize_key(key: str) -> str:
        return re.sub(r"[^a-z0-9]", "", key.lower())

    if isinstance(node, dict):
        for key, value in node.items():
            if normalize_key(key) in wanted_keys:
                out.append(value)
            _collect_values_by_key(value, wanted_keys, out)
    elif isinstance(node, list):
        for item in node:
            _collect_values_by_key(item, wanted_keys, out)


def find_first_non_empty(data: object, keys: List[str]) -> Optional[object]:
    wanted_keys = {re.sub(r"[^a-z0-9]", "", k.lower()) for k in keys}
    candidates: List[object] = []
    _collect_values_by_key(data, wanted_keys, candidates)
    for value in candidates:
        if value is None:
            continue
        if isinstance(value, str) and value.strip() == "":
            continue
        return value
    return None


def count_extracted_fields(info: Dict[str, Optional[str]]) -> int:
    return sum(1 for key in TARGET_ENRICH_FIELDS if info.get(key) not in (None, ""))


def get_player_info_from_stats_api(
    person_id: int, request_timeout: float
) -> Dict[str, Optional[str]]:
    url = (
        "https://stats.nba.com/stats/commonplayerinfo"
        f"?LeagueID=00&PlayerID={person_id}"
    )
    response = requests.get(url, headers=NBA_STATS_HEADERS, timeout=request_timeout)
    response.raise_for_status()
    payload = response.json()

    result_sets = payload.get("resultSets", [])
    if not result_sets:
        return {}

    headers = result_sets[0].get("headers", [])
    row_set = result_sets[0].get("rowSet", [])
    if not row_set:
        return {}

    values = dict(zip(headers, row_set[0]))
    draft = parse_draft_components(
        values.get("DRAFT_YEAR"),
        values.get("DRAFT_ROUND"),
        values.get("DRAFT_NUMBER"),
        values.get("DRAFT"),
    )
    return {
        "birthdate": values.get("BIRTHDATE"),
        "school": values.get("SCHOOL"),
        "country": values.get("COUNTRY"),
        "heightinches": parse_height_to_inches(values.get("HEIGHT")),
        "bodyweightlbs": parse_weight_to_lbs(values.get("WEIGHT")),
        "draftyear": draft["draftyear"],
        "draftround": draft["draftround"],
        "draftnumber": draft["draftnumber"],
        "source_url": url,
        "source_type": "stats_api",
    }


def get_player_info_from_nba_profile_page(
    person_id: int, request_timeout: float
) -> Dict[str, Optional[str]]:
    url = f"https://www.nba.com/player/{person_id}"
    response = requests.get(url, headers=NBA_STATS_HEADERS, timeout=request_timeout)
    response.raise_for_status()

    soup = BeautifulSoup(response.text, "html.parser")
    next_data_tag = soup.find("script", {"id": "__NEXT_DATA__"})
    if not next_data_tag or not next_data_tag.text:
        return {}

    data = json.loads(next_data_tag.text)
    info_node = (
        data.get("props", {})
        .get("pageProps", {})
        .get("player", {})
        .get("info", {})
    )

    birthdate_raw = info_node.get("BIRTHDATE") or find_first_non_empty(
        data, ["birthdate", "birthDate", "BIRTHDATE"]
    )
    school_raw = info_node.get("SCHOOL") or find_first_non_empty(
        data, ["school", "college", "schoolName", "SCHOOL"]
    )
    country_raw = info_node.get("COUNTRY") or find_first_non_empty(
        data, ["country", "countryName", "birthCountry", "COUNTRY"]
    )
    height_raw = find_first_non_empty(
        info_node if info_node else data,
        [
            "height",
            "heightInches",
            "heightCms",
            "heightCm",
            "heightMeters",
            "HEIGHT",
            "HEIGHT_INCHES",
        ],
    )
    weight_raw = find_first_non_empty(
        info_node if info_node else data,
        ["weight", "weightLbs", "weightPounds", "weightKg", "WEIGHT"],
    )
    draft_year_raw = info_node.get("DRAFT_YEAR") or find_first_non_empty(
        data, ["draftYear", "draftyear", "draft_year", "DRAFT_YEAR"]
    )
    draft_round_raw = info_node.get("DRAFT_ROUND") or find_first_non_empty(
        data, ["draftRound", "draftround", "draft_round", "DRAFT_ROUND"]
    )
    draft_pick_raw = info_node.get("DRAFT_NUMBER") or find_first_non_empty(
        data, ["draftNumber", "draftPick", "draftnumber", "draft_number", "DRAFT_NUMBER"]
    )
    draft_text_raw = find_first_non_empty(
        data,
        [
            "draft",
            "draftInfo",
            "draftSummary",
            "draftDescription",
            "draftDisplay",
            "draftStatus",
        ],
    )
    text_payload = json.dumps(data)
    if draft_text_raw is None:
        draft_text_match = re.search(
            r"\b((?:19|20)\d{2}\s*R(?:ound)?\s*[0-9]{1,2}\s*Pick\s*[0-9]{1,3})\b",
            text_payload,
            flags=re.IGNORECASE,
        )
        if draft_text_match:
            draft_text_raw = draft_text_match.group(1)

    draft = parse_draft_components(
        draft_year_raw, draft_round_raw, draft_pick_raw, draft_text_raw
    )
    if (
        draft["draftyear"] is not None
        and draft["draftround"] is not None
        and draft["draftnumber"] is None
    ):
        pick_match_payload = re.search(
            r"\bPick\s*#?\s*([0-9]{1,3})\b",
            text_payload,
            flags=re.IGNORECASE,
        )
        if not pick_match_payload:
            pick_match_payload = re.search(
                r"\b([0-9]{1,3})(?:st|nd|rd|th)\s+overall\b",
                text_payload,
                flags=re.IGNORECASE,
            )
        if pick_match_payload:
            draft["draftnumber"] = pick_match_payload.group(1)

    return {
        "birthdate": str(birthdate_raw).strip() if birthdate_raw is not None else None,
        "school": str(school_raw).strip() if school_raw is not None else None,
        "country": str(country_raw).strip() if country_raw is not None else None,
        "heightinches": parse_height_any_to_inches(height_raw),
        "bodyweightlbs": parse_weight_to_lbs(str(weight_raw)) if weight_raw is not None else None,
        "draftyear": draft["draftyear"],
        "draftround": draft["draftround"],
        "draftnumber": draft["draftnumber"],
        "source_url": url,
        "source_type": "nba_profile_page",
    }


def get_prioritized_players_with_nulls(
    client: bigquery.Client,
    project_id: str,
    curated_dataset: str,
    batch_size: int,
    season: str,
) -> List[bigquery.table.Row]:
    query = f"""
    WITH target AS (
      SELECT
        p.personid,
        p.firstname,
        p.lastname
      FROM `{project_id}.{curated_dataset}.players` p
      WHERE {NULL_LIKE_SQL}
    ),
    scored AS (
      SELECT
        personid,
        SUM(CAST(points AS FLOAT64)) AS total_points
      FROM `{project_id}.{curated_dataset}.player_statistics`
      WHERE season = @season
      GROUP BY personid
    )
    SELECT
      t.personid,
      t.firstname,
      t.lastname,
      COALESCE(s.total_points, 0) AS total_points
    FROM target t
    LEFT JOIN scored s
      ON t.personid = s.personid
    ORDER BY total_points DESC, t.lastname, t.firstname
    LIMIT @batch_size
    """

    job_config = bigquery.QueryJobConfig(
        query_parameters=[
            bigquery.ScalarQueryParameter("season", "STRING", season),
            bigquery.ScalarQueryParameter("batch_size", "INT64", batch_size),
        ]
    )
    return list(client.query(query, job_config=job_config).result())


def ensure_datasets_and_tables(
    client: bigquery.Client, project_id: str, enrichment_dataset: str, curated_dataset: str
) -> None:
    client.query(
        f"CREATE SCHEMA IF NOT EXISTS `{project_id}.{enrichment_dataset}`"
    ).result()

    client.query(
        f"""
        CREATE TABLE IF NOT EXISTS `{project_id}.{enrichment_dataset}.players_scraped_staging` (
          personid INT64,
          firstname STRING,
          lastname STRING,
          birthdate STRING,
          school STRING,
          country STRING,
          heightinches FLOAT64,
          bodyweightlbs FLOAT64,
          draftyear STRING,
          draftround STRING,
          draftnumber STRING,
          source_type STRING,
          source_url STRING,
          scraped_at TIMESTAMP,
          pipeline_run_id STRING
        )
        """
    ).result()

    client.query(
        f"""
        CREATE TABLE IF NOT EXISTS `{project_id}.{curated_dataset}.players_enriched` AS
        SELECT
          *,
          CURRENT_TIMESTAMP() AS enriched_at,
          'bootstrap_from_curated' AS enrichment_source,
          CAST(NULL AS STRING) AS enrichment_run_id
        FROM `{project_id}.{curated_dataset}.players`
        WHERE 1 = 0
        """
    ).result()


def merge_enrichment(
    client: bigquery.Client,
    project_id: str,
    enrichment_dataset: str,
    curated_dataset: str,
    pipeline_run_id: str,
) -> None:
    query = f"""
    MERGE `{project_id}.{curated_dataset}.players_enriched` T
    USING (
      SELECT
        s.personid,
        ANY_VALUE(s.firstname) AS firstname,
        ANY_VALUE(s.lastname) AS lastname,
        ANY_VALUE(s.birthdate) AS birthdate,
        ANY_VALUE(s.school) AS school,
        ANY_VALUE(s.country) AS country,
        ANY_VALUE(s.heightinches) AS heightinches,
        ANY_VALUE(s.bodyweightlbs) AS bodyweightlbs,
        ANY_VALUE(s.draftyear) AS draftyear,
        ANY_VALUE(s.draftround) AS draftround,
        ANY_VALUE(s.draftnumber) AS draftnumber,
        ANY_VALUE(s.source_type) AS source_type,
        ANY_VALUE(s.source_url) AS source_url,
        MAX(s.scraped_at) AS scraped_at
      FROM `{project_id}.{enrichment_dataset}.players_scraped_staging` s
      WHERE s.pipeline_run_id = @pipeline_run_id
      GROUP BY s.personid
    ) S
    ON T.personid = S.personid
    WHEN MATCHED THEN
      UPDATE SET
        T.birthdate = COALESCE(T.birthdate, S.birthdate),
        T.school = COALESCE(T.school, S.school),
        T.country = COALESCE(T.country, S.country),
        T.heightinches = COALESCE(T.heightinches, S.heightinches),
        T.bodyweightlbs = COALESCE(T.bodyweightlbs, S.bodyweightlbs),
        T.draftyear = COALESCE(T.draftyear, SAFE_CAST(S.draftyear AS INT64)),
        T.draftround = COALESCE(T.draftround, SAFE_CAST(S.draftround AS INT64)),
        T.draftnumber = COALESCE(T.draftnumber, SAFE_CAST(S.draftnumber AS INT64)),
        T.enriched_at = CURRENT_TIMESTAMP(),
        T.enrichment_source = S.source_type,
        T.enrichment_run_id = @pipeline_run_id
    WHEN NOT MATCHED THEN
      INSERT (
        personid, firstname, lastname, birthdate, school, country,
        heightinches, bodyweightlbs, guard, forward, center,
        draftyear, draftround, draftnumber, height_m, weight_kg,
        updated_at, enriched_at, enrichment_source, enrichment_run_id
      )
      VALUES (
        S.personid, S.firstname, S.lastname, S.birthdate, S.school, S.country,
        S.heightinches, S.bodyweightlbs, NULL, NULL, NULL,
        SAFE_CAST(S.draftyear AS INT64),
        SAFE_CAST(S.draftround AS INT64),
        SAFE_CAST(S.draftnumber AS INT64),
        ROUND(S.heightinches * 0.0254, 3),
        ROUND(S.bodyweightlbs * 0.45359237, 2),
        CURRENT_TIMESTAMP(), CURRENT_TIMESTAMP(), S.source_type, @pipeline_run_id
      )
    """
    job_config = bigquery.QueryJobConfig(
        query_parameters=[
            bigquery.ScalarQueryParameter("pipeline_run_id", "STRING", pipeline_run_id)
        ]
    )
    client.query(query, job_config=job_config).result()


def classify_exception(exc: Exception) -> str:
    if isinstance(exc, requests.Timeout):
        return "timeout"
    if isinstance(exc, requests.ConnectionError):
        return "connection_error"
    if isinstance(exc, requests.HTTPError):
        response = getattr(exc, "response", None)
        code = response.status_code if response is not None else "unknown"
        return f"http_{code}"
    return f"unexpected_{type(exc).__name__}"


def exception_details(exc: Exception) -> str:
    if isinstance(exc, requests.HTTPError):
        response = getattr(exc, "response", None)
        code = response.status_code if response is not None else "unknown"
        reason = getattr(response, "reason", "unknown")
        return f"HTTP {code} {reason}"
    return str(exc).strip().replace("\n", " ")[:240]


def main() -> None:
    parser = argparse.ArgumentParser(description="Step 2: scrape and enrich NBA players.")
    parser.add_argument("--project-id", required=True)
    parser.add_argument("--curated-dataset", default="nba_curated")
    parser.add_argument("--enrichment-dataset", default="nba_enrichment")
    parser.add_argument("--season", default="2025-2026")
    parser.add_argument("--batch-size", type=int, default=100)
    parser.add_argument("--sleep-seconds", type=float, default=0.6)
    parser.add_argument("--request-timeout", type=float, default=12.0)
    parser.add_argument("--log-every", type=int, default=5)
    parser.add_argument("--insert-batch-size", type=int, default=20)
    parser.add_argument("--skip-stats-api", action="store_true")
    parser.add_argument("--credentials-file", default="")
    args = parser.parse_args()

    if args.credentials_file:
        credentials = service_account.Credentials.from_service_account_file(
            args.credentials_file
        )
        client = bigquery.Client(project=args.project_id, credentials=credentials)
    else:
        client = bigquery.Client(project=args.project_id)
    ensure_datasets_and_tables(
        client, args.project_id, args.enrichment_dataset, args.curated_dataset
    )

    players = get_prioritized_players_with_nulls(
        client=client,
        project_id=args.project_id,
        curated_dataset=args.curated_dataset,
        batch_size=args.batch_size,
        season=args.season,
    )

    pipeline_run_id = f"run_{dt.datetime.utcnow().strftime('%Y%m%d_%H%M%S')}"
    rows_to_insert = []
    inserted_rows = 0
    success_count = 0
    fail_count = 0
    started_at = time.time()
    success_by_source = Counter()
    failure_reasons = Counter()

    def flush_rows() -> None:
        nonlocal rows_to_insert, inserted_rows
        if not rows_to_insert:
            return
        table_id_local = (
            f"{args.project_id}.{args.enrichment_dataset}.players_scraped_staging"
        )
        errors_local = client.insert_rows_json(table_id_local, rows_to_insert)
        if errors_local:
            raise RuntimeError(f"Failed inserting staging rows: {errors_local}")
        inserted_rows += len(rows_to_insert)
        print(
            f"[staging] inserted={inserted_rows} "
            f"pipeline_run_id={pipeline_run_id}",
            flush=True,
        )
        rows_to_insert = []

    total_players = len(players)
    print(
        f"[start] pipeline_run_id={pipeline_run_id} total_players={total_players}",
        flush=True,
    )

    for idx, player in enumerate(players, start=1):
        player_started_at = time.time()
        person_id = int(player["personid"])
        firstname = player["firstname"]
        lastname = player["lastname"]

        info = {}
        stats_error: Optional[Exception] = None
        profile_error: Optional[Exception] = None
        stats_empty = False
        profile_empty = False

        if not args.skip_stats_api:
            try:
                info = get_player_info_from_stats_api(person_id, args.request_timeout)
                if not info:
                    stats_empty = True
            except Exception as exc:
                stats_error = exc
                reason = f"stats_api:{classify_exception(exc)}"
                failure_reasons[reason] += 1
                print(
                    f"[warn] player={person_id} source=stats_api reason={reason} "
                    f"detail={exception_details(exc)}",
                    flush=True,
                )

        if not info:
            try:
                info = get_player_info_from_nba_profile_page(
                    person_id, args.request_timeout
                )
                if not info:
                    profile_empty = True
            except Exception as exc:
                profile_error = exc
                reason = f"profile_page:{classify_exception(exc)}"
                failure_reasons[reason] += 1
                print(
                    f"[warn] player={person_id} source=profile_page reason={reason} "
                    f"detail={exception_details(exc)}",
                    flush=True,
                )

        extracted_fields = count_extracted_fields(info)
        if info and extracted_fields > 0:
            success_count += 1
            source = info.get("source_type", "unknown")
            success_by_source[source] += 1
            print(
                f"[ok] player={person_id} source={source} "
                f"fields={extracted_fields} elapsed_s={round(time.time() - player_started_at, 2)}",
                flush=True,
            )
        else:
            fail_count += 1
            if stats_empty:
                failure_reasons["stats_api:empty_payload"] += 1
            if profile_empty:
                failure_reasons["profile_page:empty_payload"] += 1
            if info and extracted_fields == 0:
                failure_reasons["profile_page:no_fields_extracted"] += 1
            if stats_error is None and profile_error is None and not stats_empty and not profile_empty:
                failure_reasons["unknown:no_data"] += 1
            print(
                f"[fail] player={person_id} name={firstname} {lastname} "
                f"elapsed_s={round(time.time() - player_started_at, 2)}",
                flush=True,
            )

        rows_to_insert.append(
            {
                "personid": person_id,
                "firstname": firstname,
                "lastname": lastname,
                "birthdate": info.get("birthdate"),
                "school": info.get("school"),
                "country": info.get("country"),
                "heightinches": info.get("heightinches"),
                "bodyweightlbs": info.get("bodyweightlbs"),
                "draftyear": info.get("draftyear"),
                "draftround": info.get("draftround"),
                "draftnumber": info.get("draftnumber"),
                "source_type": info.get("source_type"),
                "source_url": info.get("source_url"),
                "scraped_at": dt.datetime.utcnow().isoformat(),
                "pipeline_run_id": pipeline_run_id,
            }
        )

        if idx % args.insert_batch_size == 0:
            flush_rows()

        if idx % args.log_every == 0 or idx == total_players:
            elapsed = round(time.time() - started_at, 1)
            print(
                f"[progress] {idx}/{total_players} "
                f"success={success_count} fail={fail_count} elapsed_s={elapsed}",
                flush=True,
            )

        time.sleep(args.sleep_seconds)

    flush_rows()

    print("[merge] starting merge into curated table", flush=True)
    merge_enrichment(
        client=client,
        project_id=args.project_id,
        enrichment_dataset=args.enrichment_dataset,
        curated_dataset=args.curated_dataset,
        pipeline_run_id=pipeline_run_id,
    )
    print("[merge] completed", flush=True)

    print(f"pipeline_run_id={pipeline_run_id}")
    print(f"rows_scraped={inserted_rows}")
    print(
        f"[summary] success={success_count} fail={fail_count} "
        f"success_by_source={dict(success_by_source)}",
        flush=True,
    )
    print(f"[summary] failure_reasons={dict(failure_reasons)}", flush=True)


if __name__ == "__main__":
    main()
