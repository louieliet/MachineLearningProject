CREATE OR REPLACE VIEW `bigdata2026-485103.nba_curated.v_ml_player_features`
OPTIONS (
  description = "Feature matrix for NBA win prediction. JOIN player_statistics + players. Target: win. Excludes plusMinusPoints (leakage) and DNP rows."
)
AS
SELECT
  ps.win,
  ps.home,
  ps.numminutes,
  ps.points,
  ps.assists,
  ps.blocks,
  ps.steals,
  ps.fieldgoalsattempted,
  ps.fieldgoalsmade,
  ps.fieldgoalspercentage,
  ps.threepointersattempted,
  ps.threepointersmade,
  ps.threepointerspercentage,
  ps.freethrowsattempted,
  ps.freethrowsmade,
  ps.freethrowspercentage,
  ps.reboundsdefensive,
  ps.reboundsoffensive,
  ps.reboundstotal,
  ps.foulspersonal,
  ps.turnovers,
  SAFE_DIVIDE(
    ps.fieldgoalsmade + 0.5 * ps.threepointersmade,
    ps.fieldgoalsattempted
  ) AS effective_fg_pct,
  SAFE_DIVIDE(ps.points, ps.numminutes) AS points_per_minute,
  pl.heightinches,
  pl.bodyweightlbs,
  pl.guard,
  pl.forward,
  pl.center,
  ps.season,
  ps.personid,
  ps.gameid
FROM `bigdata2026-485103.nba_curated.player_statistics` AS ps
LEFT JOIN `bigdata2026-485103.nba_curated.players` AS pl
  ON ps.personid = pl.personid
WHERE
  ps.gametype = 'Regular Season'
  AND ps.numminutes > 0;
