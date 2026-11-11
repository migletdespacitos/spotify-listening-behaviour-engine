with f as (
    select round(sum(duration_played_sec) / 60.0, 0) as minutes
    from {{ ref('marts_fct_stream_events') }}
),
d as (
    select round(sum(total_duration_minutes), 0) as minutes,
           count(*)                              as n_sessions
    from {{ ref('marts_dim_listening_sessions') }}
)
select f.minutes as fact_minutes, d.minutes as dim_minutes
from f cross join d
where abs(f.minutes - d.minutes) > greatest(1, 0.005 * d.n_sessions)
