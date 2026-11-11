/*
================================================================================
 marts_dim_listening_sessions
--------------------------------------------------------------------------------
 Grain   : one row per listening session
 Purpose : Session-level metrics for the "Session Breakdown" dashboard zone.
 Feeds   : outputs/dim_listening_sessions.csv

 total_duration_minutes = audio actually heard (sum of ms_played)
 session_span_minutes   = wall-clock span from first start to last end
                          (includes short pauses < the session gap)
 primary_* = the artist / genre with the most ms_played in the session.
             primary_genre_or_artist uses genre when known, otherwise the
             artist, so it still works on real exports without a catalog.
================================================================================
*/

with

events as (

    select *
    from {{ ref('marts_fct_stream_events') }}

),

-- -----------------------------------------------------------------------------
-- Dominant artist / genre per session (ms_played-weighted, deterministic ties)
-- -----------------------------------------------------------------------------
artist_time as (

    select session_id, artist_name, sum(duration_played_sec) as sec_played
    from events
    group by 1, 2

),

primary_artist as (

    select session_id, artist_name as primary_artist
    from artist_time
    qualify row_number() over (
        partition by session_id order by sec_played desc, artist_name
    ) = 1

),

genre_time as (

    select session_id, genre, sum(duration_played_sec) as sec_played
    from events
    group by 1, 2

),

primary_genre as (

    select session_id, genre as primary_genre
    from genre_time
    qualify row_number() over (
        partition by session_id order by sec_played desc, genre
    ) = 1

),

-- -----------------------------------------------------------------------------
-- How did the session end? (reason_end of the last event)
-- -----------------------------------------------------------------------------
session_exit as (

    select session_id, reason_end as session_end_reason
    from events
    qualify row_number() over (
        partition by session_id order by event_seq_in_session desc
    ) = 1

),

-- -----------------------------------------------------------------------------
-- Core aggregates
-- -----------------------------------------------------------------------------
session_agg as (

    select
        session_id,
        any_value(listener_id)                                     as listener_id,
        min(stream_start_ts)                                       as session_start_ts,
        max(stream_end_ts)                                         as session_end_ts,
        count(*)                                                   as total_tracks_played,
        count(*) filter (where is_qualified_stream)                as qualified_tracks_played,
        count(distinct track_name)                                 as unique_tracks,
        count(distinct artist_name)                                as unique_artists,
        round(sum(duration_played_sec) / 60.0, 2)                  as total_duration_minutes,
        count(*) filter (where skip_type = 'Complete Listen')      as complete_listens,
        count(*) filter (where skip_type = 'Explicit Skip')        as explicit_skips,
        count(*) filter (where skip_type = 'Partial Listen')       as partial_listens,
        count(*) filter (where skip_type = 'Background Exit')      as background_exits,
        bool_or(is_shuffle)                                        as used_shuffle,
        mode(platform)                                             as primary_platform
    from events
    group by 1

)

select
    s.session_id,
    s.listener_id,
    s.session_start_ts,
    s.session_end_ts,
    s.session_start_ts::date                                       as session_date,
    hour(s.session_start_ts)                                       as session_start_hour,
    dayname(s.session_start_ts)                                    as session_day_of_week,
    isodow(s.session_start_ts)                                     as session_day_of_week_num,

    s.total_tracks_played,
    s.qualified_tracks_played,
    s.unique_tracks,
    s.unique_artists,
    s.total_duration_minutes,
    round(date_diff('second', s.session_start_ts, s.session_end_ts) / 60.0, 2)
                                                                   as session_span_minutes,

    pa.primary_artist,
    pg.primary_genre,
    case
        when pg.primary_genre not in ('Unknown Genre') then pg.primary_genre
        else pa.primary_artist
    end                                                            as primary_genre_or_artist,

    s.complete_listens,
    s.explicit_skips,
    s.partial_listens,
    s.background_exits,
    round(s.explicit_skips   / s.total_tracks_played * 100, 1)     as explicit_skip_rate_pct,
    round(s.complete_listens / s.total_tracks_played * 100, 1)     as completion_rate_pct,

    case
        when s.total_duration_minutes < 15  then '1. Quick (<15m)'
        when s.total_duration_minutes < 45  then '2. Standard (15-45m)'
        when s.total_duration_minutes < 90  then '3. Long (45-90m)'
        else                                     '4. Marathon (90m+)'
    end                                                            as session_length_bucket,

    se.session_end_reason,
    s.used_shuffle,
    s.primary_platform

from session_agg      as s
left join primary_artist as pa using (session_id)
left join primary_genre  as pg using (session_id)
left join session_exit   as se using (session_id)
