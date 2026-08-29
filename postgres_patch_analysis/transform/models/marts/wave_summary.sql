{{ config(materialized='external', location='../data/derived/wave_summary.csv', format='csv') }}

SELECT *
FROM {{ ref('int_wave_summary') }}
ORDER BY wave_date
