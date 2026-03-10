CREATE SCHEMA IF NOT EXISTS `bigdata2026-485103.nba_serving`;

CREATE OR REPLACE VIEW `bigdata2026-485103.nba_serving.player_profile` AS
WITH latest_enriched AS (
  SELECT
    personid,
    firstname,
    lastname,
    birthdate,
    school,
    country,
    heightinches,
    bodyweightlbs,
    draftyear,
    draftround,
    draftnumber,
    enriched_at,
    enrichment_source,
    enrichment_run_id,
    ROW_NUMBER() OVER (PARTITION BY personid ORDER BY enriched_at DESC) AS rn
  FROM `bigdata2026-485103.nba_curated.players_enriched`
)
SELECT
  p.personid,
  COALESCE(e.firstname, p.firstname) AS firstname,
  COALESCE(e.lastname, p.lastname) AS lastname,
  COALESCE(e.birthdate, p.birthdate) AS birthdate,
  COALESCE(e.school, p.school) AS school,
  COALESCE(e.country, p.country) AS country,
  COALESCE(e.heightinches, p.heightinches) AS heightinches,
  COALESCE(e.bodyweightlbs, p.bodyweightlbs) AS bodyweightlbs,
  COALESCE(e.draftyear, p.draftyear) AS draftyear,
  COALESCE(e.draftround, p.draftround) AS draftround,
  COALESCE(e.draftnumber, p.draftnumber) AS draftnumber,
  e.enriched_at,
  e.enrichment_source,
  e.enrichment_run_id
FROM `bigdata2026-485103.nba_curated.players` p
LEFT JOIN latest_enriched e
  ON p.personid = e.personid
 AND e.rn = 1;

CREATE OR REPLACE VIEW `bigdata2026-485103.nba_serving.player_recent_form` AS
WITH base AS (
  SELECT
    personid,
    firstname,
    lastname,
    gameid,
    game_date,
    season,
    points,
    assists,
    reboundstotal,
    turnovers,
    fieldgoalspercentage,
    threepointerspercentage,
    freethrowspercentage,
    ROW_NUMBER() OVER (PARTITION BY personid ORDER BY game_date DESC, gameid DESC) AS rn
  FROM `bigdata2026-485103.nba_curated.player_statistics`
),
last10 AS (
  SELECT *
  FROM base
  WHERE rn <= 10
)
SELECT
  personid,
  ANY_VALUE(firstname) AS firstname,
  ANY_VALUE(lastname) AS lastname,
  COUNT(*) AS games_sample,
  MAX(game_date) AS last_game_date,
  ROUND(AVG(points), 2) AS avg_points_last10,
  ROUND(AVG(assists), 2) AS avg_assists_last10,
  ROUND(AVG(reboundstotal), 2) AS avg_rebounds_last10,
  ROUND(AVG(turnovers), 2) AS avg_turnovers_last10,
  ROUND(AVG(fieldgoalspercentage), 3) AS avg_fg_pct_last10,
  ROUND(AVG(threepointerspercentage), 3) AS avg_3p_pct_last10,
  ROUND(AVG(freethrowspercentage), 3) AS avg_ft_pct_last10
FROM last10
GROUP BY personid;

CREATE OR REPLACE VIEW `bigdata2026-485103.nba_serving.team_recent_form` AS
WITH base AS (
  SELECT
    teamid,
    teamname,
    gameid,
    game_date,
    season,
    win,
    teamscore,
    opponentscore,
    assists,
    reboundstotal,
    turnovers,
    fieldgoalspercentage,
    threepointerspercentage,
    freethrowspercentage,
    ROW_NUMBER() OVER (PARTITION BY teamid ORDER BY game_date DESC, gameid DESC) AS rn
  FROM `bigdata2026-485103.nba_curated.team_statistics`
),
last10 AS (
  SELECT *
  FROM base
  WHERE rn <= 10
)
SELECT
  teamid,
  ANY_VALUE(teamname) AS teamname,
  COUNT(*) AS games_sample,
  MAX(game_date) AS last_game_date,
  ROUND(AVG(CAST(win AS FLOAT64)), 3) AS win_rate_last10,
  ROUND(AVG(teamscore), 2) AS avg_team_score_last10,
  ROUND(AVG(opponentscore), 2) AS avg_opp_score_last10,
  ROUND(AVG(assists), 2) AS avg_assists_last10,
  ROUND(AVG(reboundstotal), 2) AS avg_rebounds_last10,
  ROUND(AVG(turnovers), 2) AS avg_turnovers_last10,
  ROUND(AVG(fieldgoalspercentage), 3) AS avg_fg_pct_last10,
  ROUND(AVG(threepointerspercentage), 3) AS avg_3p_pct_last10,
  ROUND(AVG(freethrowspercentage), 3) AS avg_ft_pct_last10
FROM last10
GROUP BY teamid;

CREATE OR REPLACE VIEW `bigdata2026-485103.nba_serving.player_game_features` AS
SELECT
  ps.gameid,
  ps.game_date,
  ps.season,
  ps.personid,
  pp.firstname,
  pp.lastname,
  ps.playerteamname,
  ps.opponentteamname,
  ps.home,
  ps.win,
  ps.points,
  ps.assists,
  ps.reboundstotal,
  ps.turnovers,
  ps.fieldgoalspercentage,
  ps.threepointerspercentage,
  ps.freethrowspercentage,
  prf.avg_points_last10,
  prf.avg_assists_last10,
  prf.avg_rebounds_last10,
  trf.win_rate_last10 AS team_win_rate_last10
FROM `bigdata2026-485103.nba_curated.player_statistics` ps
LEFT JOIN `bigdata2026-485103.nba_serving.player_profile` pp
  ON ps.personid = pp.personid
LEFT JOIN `bigdata2026-485103.nba_serving.player_recent_form` prf
  ON ps.personid = prf.personid
LEFT JOIN `bigdata2026-485103.nba_serving.team_recent_form` trf
  ON ps.playerteamname = trf.teamname;
