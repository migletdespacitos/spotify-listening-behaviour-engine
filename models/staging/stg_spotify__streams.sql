/*
================================================================================
 stg_spotify__streams
--------------------------------------------------------------------------------
 Grain      : one row per (de-duplicated) stream event
 Source     : Spotify Extended Streaming History JSON (endsong_*.json)
 Purpose    : Land raw JSON, enforce types, rename to clean snake_case, derive
              the stream START time, convert UTC -> listener-local time, and
              neutralise NULL metadata (podcasts, local files, unavailable
              tracks).

 Key domain fact
   Spotify's `ts` is the moment the stream ENDED (UTC). The stream started at
   ts - ms_played. Getting this wrong shifts every session boundary.
================================================================================
*/

with

-- -----------------------------------------------------------------------------
-- 1. Raw ingest straight from disk with DuckDB's JSON reader.
--    An explicit `columns` map pins the contract: keys missing from older or
--    newer export versions arrive as NULL instead of breaking type inference,
--    and unexpected extra keys are ignored.
-- -----------------------------------------------------------------------------
raw_json as (

    select *
    from read_json_auto(
        '{{ var("raw_streams_glob") }}',
        format         = 'array',
        union_by_name  = true,        -- tolerate schema drift across files
        filename       = true,        -- keep lineage to the source file
        columns = {
            ts:                                 'VARCHAR',
            username:                           'VARCHAR',
            platform:                           'VARCHAR',
            ms_played:                          'BIGINT',
            conn_country:                       'VARCHAR',
            master_metadata_track_name:         'VARCHAR',
            master_metadata_album_artist_name:  'VARCHAR',
            master_metadata_album_album_name:   'VARCHAR',
            spotify_track_uri:                  'VARCHAR',
            episode_name:                       'VARCHAR',
            episode_show_name:                  'VARCHAR',
            spotify_episode_uri:                'VARCHAR',
            reason_start:                       'VARCHAR',
            reason_end:                         'VARCHAR',
            shuffle:                            'BOOLEAN',
            skipped:                            'BOOLEAN',
            offline:                            'BOOLEAN',
            incognito_mode:                     'BOOLEAN'
        }
    )

),

-- -----------------------------------------------------------------------------
-- 2. Type casting + renaming. Timestamps are stored as naive TIMESTAMPs in two
--    explicit zones (UTC and local) so no downstream logic depends on the
--    session TimeZone setting.
-- -----------------------------------------------------------------------------
typed as (

    select
        -- identity / lineage
        coalesce(nullif(trim(username), ''), 'unknown_listener')        as listener_id,
        filename                                                        as source_file,

        -- time: `ts` = END of stream (UTC)
        timezone('UTC', ts::timestamptz)                                as stream_end_ts_utc,
        greatest(coalesce(ms_played, 0), 0)                             as ms_played,

        -- music metadata (raw, NULLs resolved in the next CTE)
        nullif(trim(master_metadata_track_name), '')                    as track_name_raw,
        nullif(trim(master_metadata_album_artist_name), '')             as artist_name_raw,
        nullif(trim(master_metadata_album_album_name), '')              as album_name_raw,
        spotify_track_uri,

        -- podcast metadata
        nullif(trim(episode_name), '')                                  as episode_name,
        nullif(trim(episode_show_name), '')                             as episode_show_name,
        spotify_episode_uri,

        -- playback context
        lower(coalesce(platform, 'unknown'))                            as platform,
        -- Real exports log full device strings ("iOS 14.5.1 (iPhone11,8)",
        -- "Partner google cast_voice;HK_Citation_One;;..."), so collapse them
        -- into families that are useful on a dashboard.
        case
            when lower(platform) like 'ios%'                                   then 'iOS'
            when lower(platform) like '%android%'                              then 'Android'
            when lower(platform) like 'web_player%'                            then 'Web Player'
            when lower(platform) like 'windows%'                               then 'Windows'
            when lower(platform) like 'os x%' or lower(platform) like 'osx%'
              or lower(platform) like '%macos%'                                then 'macOS'
            when lower(platform) like 'partner%' or lower(platform) like '%cast%' then 'Cast / Smart Speaker'
            else 'Other'
        end                                                             as platform_family,
        upper(conn_country)                                             as conn_country,
        lower(coalesce(reason_start, 'unknown'))                        as reason_start,
        lower(coalesce(reason_end, 'unknown'))                          as reason_end,
        coalesce(shuffle, false)                                        as is_shuffle,
        coalesce(skipped, false)                                        as is_skipped_flag,
        coalesce(offline, false)                                        as is_offline,
        coalesce(incognito_mode, false)                                 as is_incognito

    from raw_json
    where ts is not null                      -- a stream without a timestamp is unusable

),

-- -----------------------------------------------------------------------------
-- 3. Derive start time, local time, content type and NULL-safe labels.
-- -----------------------------------------------------------------------------
enriched as (

    select
        *,

        -- Stream START = END - ms_played
        stream_end_ts_utc - to_milliseconds(ms_played)                  as stream_start_ts_utc,

        -- Local-time equivalents for every calendar-based metric downstream
        timezone('{{ var("local_timezone") }}',
                 timezone('UTC', stream_end_ts_utc)
                 - to_milliseconds(ms_played))                          as stream_start_ts_local,
        timezone('{{ var("local_timezone") }}',
                 timezone('UTC', stream_end_ts_utc))                    as stream_end_ts_local,

        -- What was actually playing?
        case
            when track_name_raw is not null then 'music'
            when episode_name   is not null then 'podcast'
            else 'unavailable'                   -- local file / removed track / error
        end                                                             as content_type

    from typed

),

-- -----------------------------------------------------------------------------
-- 4. NULL handling for presentation columns. Podcasts are labelled by show and
--    episode so they remain analysable; truly unknown items get sentinels
--    instead of NULLs (Tableau groups NULLs awkwardly).
-- -----------------------------------------------------------------------------
labelled as (

    select
        *,
        case content_type
            when 'music'   then track_name_raw
            when 'podcast' then episode_name
            else 'Unknown Track'
        end                                                             as track_name,
        case content_type
            when 'music'   then coalesce(artist_name_raw, 'Unknown Artist')
            when 'podcast' then coalesce(episode_show_name, 'Unknown Podcast')
            else 'Unknown Artist'
        end                                                             as artist_name,
        coalesce(album_name_raw,
                 case when content_type = 'podcast' then 'Podcast' end,
                 'Unknown Album')                                       as album_name,
        coalesce(spotify_track_uri, spotify_episode_uri, 'unknown')     as content_uri
    from enriched

),

-- -----------------------------------------------------------------------------
-- 5. De-duplicate. Spotify exports occasionally contain byte-identical rows;
--    the natural key is (listener, end ts, content, ms_played).
-- -----------------------------------------------------------------------------
deduplicated as (

    select *
    from labelled
    qualify row_number() over (
        partition by listener_id, stream_end_ts_utc, content_uri, ms_played
        order by source_file
    ) = 1

)

select
    -- deterministic surrogate key
    md5(concat_ws('|', listener_id, stream_end_ts_utc::varchar,
                  content_uri, ms_played::varchar))                     as stream_event_id,
    listener_id,
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
    is_incognito,
    source_file
from deduplicated
