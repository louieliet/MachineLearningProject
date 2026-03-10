-- PASO 1: Crear el modelo
CREATE OR REPLACE MODEL `bigdata2026-485103.nba_curated.nba_win_predictor`
OPTIONS (
  model_type            = 'BOOSTED_TREE_CLASSIFIER',
  input_label_cols      = ['win'],
  data_split_method     = 'AUTO_SPLIT',
  num_parallel_tree     = 4,
  max_tree_depth        = 6,
  subsample             = 0.8,
  min_split_loss        = 0.1,
  enable_global_explain = TRUE
) AS
SELECT
  win,
  home,
  numminutes,
  points,
  assists,
  blocks,
  steals,
  fieldgoalspercentage,
  threepointerspercentage,
  freethrowspercentage,
  reboundsdefensive,
  reboundsoffensive,
  reboundstotal,
  foulspersonal,
  turnovers,
  effective_fg_pct,
  points_per_minute,
  heightinches,
  bodyweightlbs,
  guard,
  forward,
  center
FROM `bigdata2026-485103.nba_curated.v_ml_player_features`
WHERE season >= '2015-2016';


-- PASO 2: Evaluar el modelo
SELECT *
FROM ML.EVALUATE(
  MODEL `bigdata2026-485103.nba_curated.nba_win_predictor`
);


-- PASO 3: Feature importance global
SELECT
  feature,
  ROUND(importance_weight, 4) AS importance_weight,
  ROUND(importance_gain, 4)   AS importance_gain,
  ROUND(importance_cover, 4)  AS importance_cover
FROM ML.GLOBAL_EXPLAIN(
  MODEL `bigdata2026-485103.nba_curated.nba_win_predictor`
)
ORDER BY importance_gain DESC;


-- PASO 4: Prueba de inferencia
SELECT
  predicted_win,
  ROUND(
    (SELECT prob FROM UNNEST(predicted_win_probs) WHERE label = 1),
    4
  ) AS win_probability
FROM ML.PREDICT(
  MODEL `bigdata2026-485103.nba_curated.nba_win_predictor`,
  (
    SELECT
      CAST(1    AS INT64) AS home,
      36.0                AS numminutes,
      CAST(28   AS INT64) AS points,
      CAST(8    AS INT64) AS assists,
      CAST(1    AS INT64) AS blocks,
      CAST(2    AS INT64) AS steals,
      0.54                AS fieldgoalspercentage,
      0.37                AS threepointerspercentage,
      0.73                AS freethrowspercentage,
      CAST(7    AS INT64) AS reboundsdefensive,
      CAST(2    AS INT64) AS reboundsoffensive,
      CAST(9    AS INT64) AS reboundstotal,
      CAST(2    AS INT64) AS foulspersonal,
      CAST(4    AS INT64) AS turnovers,
      0.61                AS effective_fg_pct,
      0.78                AS points_per_minute,
      81.0                AS heightinches,
      250.0               AS bodyweightlbs,
      CAST(0    AS INT64) AS guard,
      CAST(1    AS INT64) AS forward,
      CAST(0    AS INT64) AS center
  )
);
