CREATE SCHEMA IF NOT EXISTS `bigdata2026-485103.nba_serving`;

CREATE OR REPLACE VIEW `bigdata2026-485103.nba_serving.player_advanced_summary` AS
WITH current_season AS (
  SELECT MAX(season_start_year) AS season_start_year
  FROM `bigdata2026-485103.nba_curated.games`
  WHERE gametype IN (
    'Regular Season',
    'Playoffs',
    'Play-in Tournament',
    'NBA Cup',
    'NBA Emirates Cup',
    'Emirates NBA Cup'
  )
),
official_player_games AS (
  SELECT
    ps.personid,
    ps.firstname,
    ps.lastname,
    ps.gameid,
    ps.game_date,
    ps.season_start_year,
    g.gametype,
    ps.home,
    ps.opponentteamname,
    ps.numminutes,
    ps.points,
    ps.assists,
    ps.reboundstotal,
    ps.reboundsoffensive,
    ps.reboundsdefensive,
    ps.blocks,
    ps.threepointersmade,
    ps.fieldgoalsattempted,
    ps.fieldgoalsmade,
    ps.freethrowsattempted
  FROM `bigdata2026-485103.nba_curated.player_statistics` ps
  JOIN `bigdata2026-485103.nba_curated.games` g
    ON ps.gameid = g.gameid
  WHERE ps.gameid IS NOT NULL
    AND ps.numminutes > 0
    AND g.gametype IN (
      'Regular Season',
      'Playoffs',
      'Play-in Tournament',
      'NBA Cup',
      'NBA Emirates Cup',
      'Emirates NBA Cup'
    )
),
current_season_games AS (
  SELECT *
  FROM official_player_games
  WHERE season_start_year = (SELECT season_start_year FROM current_season)
),
current_season_season_avg AS (
  SELECT
    personid,
    ANY_VALUE(firstname) AS firstname,
    ANY_VALUE(lastname) AS lastname,
    COUNT(*) AS games_count_current_season,
    ROUND(AVG(points), 2) AS season_avg_points,
    ROUND(AVG(reboundstotal), 2) AS season_avg_rebounds,
    ROUND(AVG(assists), 2) AS season_avg_assists,
    ROUND(AVG(blocks), 2) AS season_avg_blocks,
    ROUND(AVG(threepointersmade), 2) AS season_avg_threes_made,
    ROUND(AVG(reboundsdefensive), 2) AS season_avg_def_rebounds,
    ROUND(AVG(reboundsoffensive), 2) AS season_avg_off_rebounds,
    ROUND(STDDEV_POP(points), 2) AS season_stddev_points,
    ROUND(
      SAFE_DIVIDE(SUM(points), 2 * (SUM(fieldgoalsattempted) + 0.44 * SUM(freethrowsattempted))),
      4
    ) AS true_shooting_pct
  FROM current_season_games
  GROUP BY personid
),
current_season_last10 AS (
  SELECT *
  FROM (
    SELECT
      *,
      ROW_NUMBER() OVER (PARTITION BY personid ORDER BY game_date DESC, gameid DESC) AS rn
    FROM current_season_games
  )
  WHERE rn <= 10
),
current_season_last10_avg AS (
  SELECT
    personid,
    COUNT(*) AS games_count_last10,
    ROUND(AVG(points), 2) AS last10_avg_points,
    ROUND(AVG(reboundstotal), 2) AS last10_avg_rebounds,
    ROUND(AVG(assists), 2) AS last10_avg_assists,
    ROUND(AVG(blocks), 2) AS last10_avg_blocks,
    ROUND(AVG(threepointersmade), 2) AS last10_avg_threes_made
  FROM current_season_last10
  GROUP BY personid
),
season_type_split AS (
  SELECT
    personid,
    ROUND(AVG(IF(gametype = 'Playoffs', points, NULL)), 2) AS playoffs_avg_points,
    ROUND(AVG(IF(gametype = 'Playoffs', reboundstotal, NULL)), 2) AS playoffs_avg_rebounds,
    ROUND(AVG(IF(gametype = 'Playoffs', assists, NULL)), 2) AS playoffs_avg_assists,
    ROUND(AVG(IF(gametype = 'Regular Season', points, NULL)), 2) AS regular_avg_points,
    ROUND(AVG(IF(gametype = 'Regular Season', reboundstotal, NULL)), 2) AS regular_avg_rebounds,
    ROUND(AVG(IF(gametype = 'Regular Season', assists, NULL)), 2) AS regular_avg_assists
  FROM official_player_games
  GROUP BY personid
),
top10_defenses AS (
  SELECT teamname
  FROM (
    SELECT
      ts.teamname,
      AVG(ts.opponentscore) AS avg_points_allowed
    FROM `bigdata2026-485103.nba_curated.team_statistics` ts
    JOIN `bigdata2026-485103.nba_curated.games` g
      ON ts.gameid = g.gameid
    WHERE ts.season_start_year = (SELECT season_start_year FROM current_season)
      AND g.gametype IN (
        'Regular Season',
        'Playoffs',
        'Play-in Tournament',
        'NBA Cup',
        'NBA Emirates Cup',
        'Emirates NBA Cup'
      )
      AND ts.opponentscore IS NOT NULL
    GROUP BY ts.teamname
  )
  ORDER BY avg_points_allowed ASC
  LIMIT 10
),
vs_top10_defense AS (
  SELECT
    personid,
    ROUND(SAFE_DIVIDE(SUM(fieldgoalsmade), SUM(fieldgoalsattempted)), 4) AS fg_pct_vs_top10_defenses
  FROM current_season_games
  WHERE opponentteamname IN (SELECT teamname FROM top10_defenses)
  GROUP BY personid
)
SELECT
  s.personid,
  s.firstname,
  s.lastname,
  s.games_count_current_season,
  l.games_count_last10,
  s.season_avg_points,
  s.season_avg_rebounds,
  s.season_avg_assists,
  s.season_avg_blocks,
  s.season_avg_threes_made,
  l.last10_avg_points,
  l.last10_avg_rebounds,
  l.last10_avg_assists,
  l.last10_avg_blocks,
  l.last10_avg_threes_made,
  ROUND(SAFE_DIVIDE(l.last10_avg_points - s.season_avg_points, NULLIF(s.season_avg_points, 0)), 4) AS vs_pct_points_last10_vs_season,
  ROUND(SAFE_DIVIDE(l.last10_avg_rebounds - s.season_avg_rebounds, NULLIF(s.season_avg_rebounds, 0)), 4) AS vs_pct_rebounds_last10_vs_season,
  ROUND(SAFE_DIVIDE(l.last10_avg_assists - s.season_avg_assists, NULLIF(s.season_avg_assists, 0)), 4) AS vs_pct_assists_last10_vs_season,
  ROUND(SAFE_DIVIDE(l.last10_avg_blocks - s.season_avg_blocks, NULLIF(s.season_avg_blocks, 0)), 4) AS vs_pct_blocks_last10_vs_season,
  ROUND(SAFE_DIVIDE(l.last10_avg_threes_made - s.season_avg_threes_made, NULLIF(s.season_avg_threes_made, 0)), 4) AS vs_pct_threes_last10_vs_season,
  s.season_stddev_points,
  s.true_shooting_pct,
  vt.fg_pct_vs_top10_defenses,
  s.season_avg_def_rebounds,
  s.season_avg_off_rebounds,
  st.playoffs_avg_points,
  st.playoffs_avg_rebounds,
  st.playoffs_avg_assists,
  st.regular_avg_points,
  st.regular_avg_rebounds,
  st.regular_avg_assists
FROM current_season_season_avg s
LEFT JOIN current_season_last10_avg l
  ON s.personid = l.personid
LEFT JOIN season_type_split st
  ON s.personid = st.personid
LEFT JOIN vs_top10_defense vt
  ON s.personid = vt.personid;

CREATE OR REPLACE VIEW `bigdata2026-485103.nba_serving.player_points_vs_team` AS
WITH current_season AS (
  SELECT MAX(season_start_year) AS season_start_year
  FROM `bigdata2026-485103.nba_curated.games`
  WHERE gametype IN (
    'Regular Season',
    'Playoffs',
    'Play-in Tournament',
    'NBA Cup',
    'NBA Emirates Cup',
    'Emirates NBA Cup'
  )
),
official_player_games AS (
  SELECT
    ps.personid,
    ps.firstname,
    ps.lastname,
    ps.opponentteamname,
    ps.season_start_year,
    ps.points
  FROM `bigdata2026-485103.nba_curated.player_statistics` ps
  JOIN `bigdata2026-485103.nba_curated.games` g
    ON ps.gameid = g.gameid
  WHERE ps.gameid IS NOT NULL
    AND ps.numminutes > 0
    AND g.gametype IN (
      'Regular Season',
      'Playoffs',
      'Play-in Tournament',
      'NBA Cup',
      'NBA Emirates Cup',
      'Emirates NBA Cup'
    )
)
SELECT
  personid,
  ANY_VALUE(firstname) AS firstname,
  ANY_VALUE(lastname) AS lastname,
  opponentteamname,
  COUNT(*) AS games_historical,
  ROUND(AVG(points), 2) AS avg_points_historical,
  COUNTIF(season_start_year = (SELECT season_start_year FROM current_season)) AS games_current_season,
  ROUND(AVG(IF(season_start_year = (SELECT season_start_year FROM current_season), points, NULL)), 2) AS avg_points_current_season
FROM official_player_games
GROUP BY personid, opponentteamname;

CREATE OR REPLACE VIEW `bigdata2026-485103.nba_serving.player_conference_home_away_split` AS
WITH team_conference_map AS (
  SELECT * FROM UNNEST([
    STRUCT('Hawks' AS teamname, 'East' AS conference),
    ('Celtics', 'East'), ('Nets', 'East'), ('Hornets', 'East'), ('Bulls', 'East'),
    ('Cavaliers', 'East'), ('Pistons', 'East'), ('Pacers', 'East'), ('Heat', 'East'),
    ('Bucks', 'East'), ('Knicks', 'East'), ('Magic', 'East'), ('76ers', 'East'),
    ('Raptors', 'East'), ('Wizards', 'East'),
    ('Mavericks', 'West'), ('Nuggets', 'West'), ('Warriors', 'West'), ('Rockets', 'West'),
    ('Clippers', 'West'), ('Lakers', 'West'), ('Grizzlies', 'West'), ('Timberwolves', 'West'),
    ('Pelicans', 'West'), ('Thunder', 'West'), ('Suns', 'West'), ('Trail Blazers', 'West'),
    ('Kings', 'West'), ('Spurs', 'West'), ('Jazz', 'West')
  ])
),
official_player_games AS (
  SELECT
    ps.personid,
    ps.firstname,
    ps.lastname,
    ps.home,
    ps.opponentteamname,
    ps.points,
    ps.reboundstotal,
    ps.assists,
    ps.blocks,
    ps.threepointersmade
  FROM `bigdata2026-485103.nba_curated.player_statistics` ps
  JOIN `bigdata2026-485103.nba_curated.games` g
    ON ps.gameid = g.gameid
  WHERE ps.gameid IS NOT NULL
    AND ps.numminutes > 0
    AND g.gametype IN (
      'Regular Season',
      'Playoffs',
      'Play-in Tournament',
      'NBA Cup',
      'NBA Emirates Cup',
      'Emirates NBA Cup'
    )
)
SELECT
  pg.personid,
  ANY_VALUE(pg.firstname) AS firstname,
  ANY_VALUE(pg.lastname) AS lastname,
  IF(pg.home = 1, 'Home', 'Away') AS location_split,
  COALESCE(tcm.conference, 'Unknown') AS opponent_conference,
  COUNT(*) AS games_sample,
  ROUND(AVG(pg.points), 2) AS avg_points,
  ROUND(AVG(pg.reboundstotal), 2) AS avg_rebounds,
  ROUND(AVG(pg.assists), 2) AS avg_assists,
  ROUND(AVG(pg.blocks), 2) AS avg_blocks,
  ROUND(AVG(pg.threepointersmade), 2) AS avg_threes_made
FROM official_player_games pg
LEFT JOIN team_conference_map tcm
  ON pg.opponentteamname = tcm.teamname
GROUP BY pg.personid, location_split, opponent_conference;

CREATE OR REPLACE VIEW `bigdata2026-485103.nba_serving.team_current_overview` AS
WITH current_season AS (
  SELECT MAX(season_start_year) AS season_start_year
  FROM `bigdata2026-485103.nba_curated.games`
  WHERE gametype IN (
    'Regular Season',
    'Playoffs',
    'Play-in Tournament',
    'NBA Cup',
    'NBA Emirates Cup',
    'Emirates NBA Cup'
  )
),
official_team_games AS (
  SELECT
    ts.teamid,
    ts.teamname,
    ts.home,
    ts.win,
    ts.teamscore,
    ts.opponentscore,
    ts.plusminuspoints
  FROM `bigdata2026-485103.nba_curated.team_statistics` ts
  JOIN `bigdata2026-485103.nba_curated.games` g
    ON ts.gameid = g.gameid
  WHERE ts.gameid IS NOT NULL
    AND ts.season_start_year = (SELECT season_start_year FROM current_season)
    AND g.gametype IN (
      'Regular Season',
      'Playoffs',
      'Play-in Tournament',
      'NBA Cup',
      'NBA Emirates Cup',
      'Emirates NBA Cup'
    )
)
SELECT
  teamid,
  ANY_VALUE(teamname) AS teamname,
  COUNT(*) AS games_played,
  SUM(IF(win = 1, 1, 0)) AS wins_overall,
  SUM(IF(win = 0, 1, 0)) AS losses_overall,
  SUM(IF(home = 1 AND win = 1, 1, 0)) AS wins_home,
  SUM(IF(home = 1 AND win = 0, 1, 0)) AS losses_home,
  SUM(IF(home = 0 AND win = 1, 1, 0)) AS wins_away,
  SUM(IF(home = 0 AND win = 0, 1, 0)) AS losses_away,
  ROUND(SAFE_DIVIDE(SUM(IF(win = 1, 1, 0)), COUNT(*)), 4) AS win_pct,
  ROUND(AVG(plusminuspoints), 2) AS net_rating_proxy,
  ROUND(AVG(teamscore), 2) AS avg_points_scored,
  ROUND(AVG(opponentscore), 2) AS avg_points_allowed
FROM official_team_games
GROUP BY teamid;

CREATE OR REPLACE VIEW `bigdata2026-485103.nba_serving.team_quarter_scoring` AS
WITH current_season AS (
  SELECT MAX(season_start_year) AS season_start_year
  FROM `bigdata2026-485103.nba_curated.games`
  WHERE gametype IN (
    'Regular Season',
    'Playoffs',
    'Play-in Tournament',
    'NBA Cup',
    'NBA Emirates Cup',
    'Emirates NBA Cup'
  )
)
SELECT
  ts.teamid,
  ANY_VALUE(ts.teamname) AS teamname,
  COUNT(*) AS games_played,
  ROUND(AVG(ts.q1points), 2) AS avg_q1_points,
  ROUND(AVG(ts.q2points), 2) AS avg_q2_points,
  ROUND(AVG(ts.q3points), 2) AS avg_q3_points,
  ROUND(AVG(ts.q4points), 2) AS avg_q4_points
FROM `bigdata2026-485103.nba_curated.team_statistics` ts
JOIN `bigdata2026-485103.nba_curated.games` g
  ON ts.gameid = g.gameid
WHERE ts.gameid IS NOT NULL
  AND ts.season_start_year = (SELECT season_start_year FROM current_season)
  AND g.gametype IN (
    'Regular Season',
    'Playoffs',
    'Play-in Tournament',
    'NBA Cup',
    'NBA Emirates Cup',
    'Emirates NBA Cup'
  )
GROUP BY ts.teamid;

CREATE OR REPLACE VIEW `bigdata2026-485103.nba_serving.team_record_vs_top5` AS
WITH current_season AS (
  SELECT MAX(season_start_year) AS season_start_year
  FROM `bigdata2026-485103.nba_curated.games`
  WHERE gametype IN (
    'Regular Season',
    'Playoffs',
    'Play-in Tournament',
    'NBA Cup',
    'NBA Emirates Cup',
    'Emirates NBA Cup'
  )
),
team_win_pct AS (
  SELECT
    ts.teamid,
    ANY_VALUE(ts.teamname) AS teamname,
    SAFE_DIVIDE(SUM(IF(ts.win = 1, 1, 0)), COUNT(*)) AS win_pct
  FROM `bigdata2026-485103.nba_curated.team_statistics` ts
  JOIN `bigdata2026-485103.nba_curated.games` g
    ON ts.gameid = g.gameid
  WHERE ts.gameid IS NOT NULL
    AND ts.season_start_year = (SELECT season_start_year FROM current_season)
    AND g.gametype IN (
      'Regular Season',
      'Playoffs',
      'Play-in Tournament',
      'NBA Cup',
      'NBA Emirates Cup',
      'Emirates NBA Cup'
    )
  GROUP BY ts.teamid
),
top5 AS (
  SELECT teamid
  FROM team_win_pct
  ORDER BY win_pct DESC
  LIMIT 5
)
SELECT
  ts.teamid,
  ANY_VALUE(ts.teamname) AS teamname,
  COUNTIF(ts.opponentteamid IN (SELECT teamid FROM top5)) AS games_vs_top5,
  SUM(IF(ts.opponentteamid IN (SELECT teamid FROM top5) AND ts.win = 1, 1, 0)) AS wins_vs_top5,
  SUM(IF(ts.opponentteamid IN (SELECT teamid FROM top5) AND ts.win = 0, 1, 0)) AS losses_vs_top5,
  ROUND(
    SAFE_DIVIDE(
      SUM(IF(ts.opponentteamid IN (SELECT teamid FROM top5) AND ts.win = 1, 1, 0)),
      NULLIF(COUNTIF(ts.opponentteamid IN (SELECT teamid FROM top5)), 0)
    ),
    4
  ) AS win_pct_vs_top5
FROM `bigdata2026-485103.nba_curated.team_statistics` ts
JOIN `bigdata2026-485103.nba_curated.games` g
  ON ts.gameid = g.gameid
WHERE ts.gameid IS NOT NULL
  AND ts.season_start_year = (SELECT season_start_year FROM current_season)
  AND g.gametype IN (
    'Regular Season',
    'Playoffs',
    'Play-in Tournament',
    'NBA Cup',
    'NBA Emirates Cup',
    'Emirates NBA Cup'
  )
GROUP BY ts.teamid;

CREATE OR REPLACE VIEW `bigdata2026-485103.nba_serving.team_player_leaders` AS
WITH current_season AS (
  SELECT MAX(season_start_year) AS season_start_year
  FROM `bigdata2026-485103.nba_curated.games`
  WHERE gametype IN (
    'Regular Season',
    'Playoffs',
    'Play-in Tournament',
    'NBA Cup',
    'NBA Emirates Cup',
    'Emirates NBA Cup'
  )
),
player_team_agg AS (
  SELECT
    ps.playerteamname AS teamname,
    ps.personid,
    ANY_VALUE(ps.firstname) AS firstname,
    ANY_VALUE(ps.lastname) AS lastname,
    COUNT(*) AS games_played,
    ROUND(AVG(ps.points), 2) AS avg_points,
    ROUND(AVG(ps.reboundstotal), 2) AS avg_rebounds,
    ROUND(AVG(ps.assists), 2) AS avg_assists,
    ROUND(AVG(ps.blocks), 2) AS avg_blocks,
    ROUND(AVG(ps.threepointersmade), 2) AS avg_threes_made
  FROM `bigdata2026-485103.nba_curated.player_statistics` ps
  JOIN `bigdata2026-485103.nba_curated.games` g
    ON ps.gameid = g.gameid
  WHERE ps.gameid IS NOT NULL
    AND ps.numminutes > 0
    AND ps.season_start_year = (SELECT season_start_year FROM current_season)
    AND g.gametype IN (
      'Regular Season',
      'Playoffs',
      'Play-in Tournament',
      'NBA Cup',
      'NBA Emirates Cup',
      'Emirates NBA Cup'
    )
  GROUP BY ps.playerteamname, ps.personid
)
SELECT
  teamname,
  personid,
  firstname,
  lastname,
  games_played,
  avg_points,
  avg_rebounds,
  avg_assists,
  avg_blocks,
  avg_threes_made,
  ROW_NUMBER() OVER (PARTITION BY teamname ORDER BY avg_points DESC, games_played DESC) AS rank_points,
  ROW_NUMBER() OVER (PARTITION BY teamname ORDER BY avg_rebounds DESC, games_played DESC) AS rank_rebounds,
  ROW_NUMBER() OVER (PARTITION BY teamname ORDER BY avg_assists DESC, games_played DESC) AS rank_assists,
  ROW_NUMBER() OVER (PARTITION BY teamname ORDER BY avg_blocks DESC, games_played DESC) AS rank_blocks,
  ROW_NUMBER() OVER (PARTITION BY teamname ORDER BY avg_threes_made DESC, games_played DESC) AS rank_threes
FROM player_team_agg;

CREATE OR REPLACE VIEW `bigdata2026-485103.nba_serving.team_upcoming_games` AS
SELECT
  gameid,
  game_date,
  season,
  hometeamid,
  hometeamname,
  awayteamid,
  awayteamname,
  gametype
FROM `bigdata2026-485103.nba_curated.games`
WHERE game_date > CURRENT_DATE()
  AND gametype IN (
    'Regular Season',
    'Playoffs',
    'Play-in Tournament',
    'NBA Cup',
    'NBA Emirates Cup',
    'Emirates NBA Cup'
  );

CREATE OR REPLACE VIEW `bigdata2026-485103.nba_serving.player_on_off_rating_placeholder` AS
SELECT
  CAST(NULL AS INT64) AS personid,
  CAST(NULL AS FLOAT64) AS on_off_rating,
  'NOT_AVAILABLE_IN_CURRENT_SOURCE' AS status;
