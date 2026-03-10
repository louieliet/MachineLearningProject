#!/usr/bin/env python3
import argparse
from typing import Dict

from pyspark.sql import DataFrame, SparkSession, functions as F
from pyspark.sql.types import StringType


NULL_LIKE_VALUES = ["", "null", "none", "nan", "na", "n/a", "undefined"]


def normalize_string_nulls(df: DataFrame) -> DataFrame:
    result = df
    for field in result.schema.fields:
        if isinstance(field.dataType, StringType):
            col = F.trim(F.col(field.name))
            result = result.withColumn(
                field.name,
                F.when(
                    F.lower(col).isin(*NULL_LIKE_VALUES) | col.eqNullSafe(""),
                    F.lit(None),
                ).otherwise(col),
            )
    return result


def cast_columns(df: DataFrame, casts: Dict[str, str]) -> DataFrame:
    result = df
    for col_name, target_type in casts.items():
        if col_name in result.columns:
            result = result.withColumn(col_name, F.col(col_name).cast(target_type))
    return result


def add_nba_season(df: DataFrame, datetime_col: str = "gamedatetimeest") -> DataFrame:
    if datetime_col not in df.columns:
        return df

    game_date = F.to_date(F.col(datetime_col))
    start_year = F.when(F.month(game_date) >= 10, F.year(game_date)).otherwise(
        F.year(game_date) - 1
    )
    end_year = start_year + F.lit(1)
    season = F.concat_ws("-", start_year.cast("string"), end_year.cast("string"))

    return (
        df.withColumn("game_date", game_date)
        .withColumn("season_start_year", start_year.cast("int"))
        .withColumn("season", season)
    )


def write_hive_table(
    df: DataFrame,
    full_table_name: str,
    partition_col: str = "",
    mode: str = "overwrite",
) -> None:
    writer = df.write.mode(mode).format("parquet")
    if partition_col and partition_col in df.columns:
        writer = writer.partitionBy(partition_col)
    writer.saveAsTable(full_table_name)


def write_bigquery_table(
    df: DataFrame,
    project_id: str,
    dataset: str,
    table: str,
    temporary_gcs_bucket: str,
    mode: str = "overwrite",
) -> None:
    (
        df.write.format("bigquery")
        .option("table", f"{project_id}.{dataset}.{table}")
        .option("temporaryGcsBucket", temporary_gcs_bucket)
        .mode(mode)
        .save()
    )


def main() -> None:
    parser = argparse.ArgumentParser(
        description="Step 1: modernize and clean Hive NBA tables with Spark."
    )
    parser.add_argument("--source-db", default="nba_insights")
    parser.add_argument("--target-db", default="nba_curated")
    parser.add_argument(
        "--target-db-location",
        default="",
        help="GCS location for target Hive database (required in this cluster).",
    )
    parser.add_argument("--write-bigquery", action="store_true")
    parser.add_argument("--bq-project", default="")
    parser.add_argument("--bq-dataset", default="nba_curated")
    parser.add_argument("--temporary-gcs-bucket", default="")
    args = parser.parse_args()

    spark = (
        SparkSession.builder.appName("step1-modernize-clean-spark")
        .enableHiveSupport()
        .getOrCreate()
    )

    if args.target_db_location:
        spark.sql(
            f"CREATE DATABASE IF NOT EXISTS {args.target_db} "
            f"LOCATION '{args.target_db_location}'"
        )
    else:
        spark.sql(f"CREATE DATABASE IF NOT EXISTS {args.target_db}")

    players_casts = {
        "personid": "long",
        "heightinches": "double",
        "bodyweightlbs": "double",
        "guard": "int",
        "forward": "int",
        "center": "int",
        "draftyear": "int",
        "draftround": "int",
        "draftnumber": "int",
    }

    games_casts = {
        "gameid": "long",
        "hometeamid": "long",
        "awayteamid": "long",
        "homescore": "int",
        "awayscore": "int",
        "attendance": "int",
    }

    team_stats_casts = {
        "gameid": "long",
        "teamid": "long",
        "opponentteamid": "long",
        "home": "int",
        "win": "int",
        "teamscore": "int",
        "opponentscore": "int",
        "assists": "int",
        "blocks": "int",
        "steals": "int",
        "fieldgoalsattempted": "int",
        "fieldgoalsmade": "int",
        "fieldgoalspercentage": "double",
        "threepointersattempted": "int",
        "threepointersmade": "int",
        "threepointerspercentage": "double",
        "freethrowsattempted": "int",
        "freethrowsmade": "int",
        "freethrowspercentage": "double",
        "reboundsdefensive": "int",
        "reboundsoffensive": "int",
        "reboundstotal": "int",
        "foulspersonal": "int",
        "turnovers": "int",
        "plusminuspoints": "int",
        "numminutes": "double",
        "q1points": "int",
        "q2points": "int",
        "q3points": "int",
        "q4points": "int",
        "benchpoints": "int",
        "biggestlead": "int",
        "biggestscoringrun": "int",
        "leadchanges": "int",
        "pointsfastbreak": "int",
        "pointsfromturnovers": "int",
        "pointsinthepaint": "int",
        "pointssecondchance": "int",
        "timestied": "int",
        "timeoutsremaining": "int",
        "seasonwins": "int",
        "seasonlosses": "int",
        "coachid": "long",
    }

    player_stats_casts = {
        "personid": "long",
        "gameid": "long",
        "win": "int",
        "home": "int",
        "numminutes": "double",
        "points": "int",
        "assists": "int",
        "blocks": "int",
        "steals": "int",
        "fieldgoalsattempted": "int",
        "fieldgoalsmade": "int",
        "fieldgoalspercentage": "double",
        "threepointersattempted": "int",
        "threepointersmade": "int",
        "threepointerspercentage": "double",
        "freethrowsattempted": "int",
        "freethrowsmade": "int",
        "freethrowspercentage": "double",
        "reboundsdefensive": "int",
        "reboundsoffensive": "int",
        "reboundstotal": "int",
        "foulspersonal": "int",
        "turnovers": "int",
        "plusminuspoints": "int",
    }

    players = spark.table(f"{args.source_db}.players")
    players = normalize_string_nulls(players)
    players = cast_columns(players, players_casts)
    players = (
        players.withColumn("height_m", F.round(F.col("heightinches") * F.lit(0.0254), 3))
        .withColumn("weight_kg", F.round(F.col("bodyweightlbs") * F.lit(0.45359237), 2))
        .withColumn("updated_at", F.current_timestamp())
    )

    games = spark.table(f"{args.source_db}.games")
    games = normalize_string_nulls(games)
    games = cast_columns(games, games_casts)
    games = add_nba_season(games)
    games = games.withColumn("updated_at", F.current_timestamp())

    team_stats = spark.table(f"{args.source_db}.team_statistics")
    team_stats = normalize_string_nulls(team_stats)
    team_stats = cast_columns(team_stats, team_stats_casts)
    team_stats = add_nba_season(team_stats)
    team_stats = team_stats.withColumn("updated_at", F.current_timestamp())

    player_stats = spark.table(f"{args.source_db}.player_statistics")
    player_stats = normalize_string_nulls(player_stats)
    player_stats = cast_columns(player_stats, player_stats_casts)
    player_stats = add_nba_season(player_stats)
    player_stats = player_stats.withColumn("updated_at", F.current_timestamp())

    write_hive_table(players, f"{args.target_db}.players", mode="overwrite")
    write_hive_table(games, f"{args.target_db}.games", partition_col="season", mode="overwrite")
    write_hive_table(
        team_stats,
        f"{args.target_db}.team_statistics",
        partition_col="season",
        mode="overwrite",
    )
    write_hive_table(
        player_stats,
        f"{args.target_db}.player_statistics",
        partition_col="season",
        mode="overwrite",
    )

    if args.write_bigquery:
        if not args.bq_project or not args.temporary_gcs_bucket:
            raise ValueError(
                "For --write-bigquery you must provide --bq-project and "
                "--temporary-gcs-bucket"
            )

        write_bigquery_table(
            players,
            project_id=args.bq_project,
            dataset=args.bq_dataset,
            table="players",
            temporary_gcs_bucket=args.temporary_gcs_bucket,
            mode="overwrite",
        )
        write_bigquery_table(
            games,
            project_id=args.bq_project,
            dataset=args.bq_dataset,
            table="games",
            temporary_gcs_bucket=args.temporary_gcs_bucket,
            mode="overwrite",
        )
        write_bigquery_table(
            team_stats,
            project_id=args.bq_project,
            dataset=args.bq_dataset,
            table="team_statistics",
            temporary_gcs_bucket=args.temporary_gcs_bucket,
            mode="overwrite",
        )
        write_bigquery_table(
            player_stats,
            project_id=args.bq_project,
            dataset=args.bq_dataset,
            table="player_statistics",
            temporary_gcs_bucket=args.temporary_gcs_bucket,
            mode="overwrite",
        )

    spark.stop()


if __name__ == "__main__":
    main()
