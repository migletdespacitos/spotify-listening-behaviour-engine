with

events as (

    select *
    from {{ ref('int_spotify__sessionized_events') }}

),

catalog as (

    select *
    from {{ ref('stg_spotify__track_catalog') }}

),
observed_durations as (

    select
        spotify_track_uri,
        max(ms_played)                                      as observed_duration_ms
    from events
    where content_type = 'music'
      and reason_end   = 'trackdone'
      and spotify_track_uri is not null
    group by 1

),
with_duration as (

    select
        e.*,
        coalesce(c.duration_ms, o.observed_duration_ms)     as track_duration_ms,
        case
            when c.duration_ms is not null           then 'catalog'
            when o.observed_duration_ms is not null  then 'observed_max_trackdone'
            else 'unknown'
        end                                                 as duration_source,
        case
            when e.content_type = 'podcast' then 'Podcast'
            else coalesce(c.genre, 'Unknown Genre')
        end                                                 as genre
    from events as e
    left join catalog as c
        on e.spotify_track_uri = c.spotify_track_uri
    left join observed_durations as o
        on e.spotify_track_uri = o.spotify_track_uri

),

with_pct as (

    select
        *,
        case
            when track_duration_ms > 0
                then least(ms_played::double / track_duration_ms, 1.0)
        end                                                 as pct_played
    from with_duration

),
classified as (

    select
        *,
        case
            -- 1. Heard (nearly) the whole thing
            when pct_played >= {{ var('complete_listen_pct_threshold') }}
              or (pct_played is null and reason_end = 'trackdone')
                then 'Complete Listen'

            -- 2. Rejected within the first 30 seconds with the next button
            when ms_played < {{ var('explicit_skip_max_ms') }}
             and reason_end = 'fwdbtn'
                then 'Explicit Skip'

            -- 3. Playback stopped by the app / device / system
            when reason_end in (
                    'logout',
                    'unexpected-exit',
                    'unexpected-exit-while-playing',
                    'unexpected-exit-while-paused',
                    'remote',
                    'trackerror',
                    'unknown'
                 )
                then 'Background Exit'

            -- 4. Any other deliberate listener action (late fwdbtn, backbtn,
            --    clickrow, endplay)
            else 'Partial Listen'
        end                                                 as skip_type
    from with_pct

)

select
    *,
    (skip_type = 'Explicit Skip')                           as is_explicit_skip,
    (skip_type in ('Explicit Skip', 'Partial Listen'))      as is_any_skip,
    (skip_type = 'Complete Listen')                         as is_complete_listen,
    (ms_played >= {{ var('qualified_stream_min_ms') }})     as is_qualified_stream,
    (ms_played < 1000)                                      as is_micro_play
from classified
