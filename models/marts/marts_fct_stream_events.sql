/*
================================================================================
 marts_fct_stream_events
--------------------------------------------------------------------------------
 Grain   : one row per stream event
 Purpose : Denormalised, BI-ready event fact. Every calendar attribute is
           pre-computed in LOCAL time so Tableau never has to do time-zone
           maths, and every label is human readable.
 Feeds   : outputs/fact_stream_events.csv
================================================================================
*/

with

events as (

    select *
    from {{ ref('int_spotify__skip_classification') }}

)

select
    -- keys
    stream_event_id,
    session_id,
    listener_id,
    event_seq_in_session,

    -- time (local)
    stream_start_ts_local                                  as stream_start_ts,
    stream_end_ts_local                                    as stream_end_ts,
    stream_start_ts_local::date                            as event_date,
    hour(stream_start_ts_local)                            as hour_of_day,
    dayname(stream_start_ts_local)                         as day_of_week,
    isodow(stream_start_ts_local)                          as day_of_week_num,    -- 1 = Monday (sort key)
    case
        when isodow(stream_start_ts_local) >= 6 then 'Weekend'
        else 'Weekday'
    end                                                    as day_type,
    case
        when hour(stream_start_ts_local) between 5  and 11 then 'Morning'
        when hour(stream_start_ts_local) between 12 and 16 then 'Afternoon'
        when hour(stream_start_ts_local) between 17 and 21 then 'Evening'
        else 'Late Night'
    end                                                    as daypart,

    -- content
    content_type,
    artist_name,
    track_name,
    album_name,
    genre,

    -- engagement
    round(ms_played / 1000.0, 1)                           as duration_played_sec,
    round(track_duration_ms / 1000.0, 1)                   as track_duration_sec,
    round(pct_played * 100, 1)                             as pct_played,
    skip_type,
    is_explicit_skip,
    is_any_skip,
    is_complete_listen,
    is_qualified_stream,
    is_micro_play,

    -- playback context
    reason_start,
    reason_end,
    platform_family                                        as platform,
    is_shuffle,
    is_session_start,
    round(gap_from_prev_sec, 1)                            as gap_from_prev_sec

from events
