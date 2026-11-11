with

events as (

    select *
    from {{ ref('stg_spotify__streams') }}

),
with_previous as (

    select
        *,
        lag(stream_end_ts_utc) over listener_timeline       as prev_stream_end_ts_utc,
        date_diff(
            'millisecond',
            lag(stream_end_ts_utc) over listener_timeline,
            stream_start_ts_utc
        ) / 1000.0                                          as gap_from_prev_sec
    from events
    window listener_timeline as (
        partition by listener_id
        order by stream_start_ts_utc, stream_end_ts_utc, stream_event_id
    )

),
flagged as (

    select
        *,
        case
            when prev_stream_end_ts_utc is null                          then 1
            when gap_from_prev_sec > {{ var('session_gap_seconds') }}    then 1
            else 0
        end                                                 as is_new_session
    from with_previous

),
numbered as (

    select
        *,
        sum(is_new_session) over (
            partition by listener_id
            order by stream_start_ts_utc, stream_end_ts_utc, stream_event_id
            rows between unbounded preceding and current row
        )                                                   as session_number
    from flagged

)

select
    stream_event_id,
    listener_id,
    listener_id || '-S' || lpad(session_number::varchar, 5, '0')   as session_id,
    session_number,
    row_number() over (
        partition by listener_id, session_number
        order by stream_start_ts_utc, stream_end_ts_utc, stream_event_id
    )                                                               as event_seq_in_session,

    is_new_session::boolean                                         as is_session_start,
    gap_from_prev_sec,

    stream_start_ts_utc,
    stream_end_ts_utc,
    stream_start_ts_local,
    stream_end_ts_local,
    ms_played,
    content_type,
    track_name,
    artist_name,
    album_name,
    content_uri,
    spotify_track_uri,
    platform,
    platform_family,
    conn_country,
    reason_start,
    reason_end,
    is_shuffle,
    is_skipped_flag,
    is_offline,
    is_incognito
from numbered
