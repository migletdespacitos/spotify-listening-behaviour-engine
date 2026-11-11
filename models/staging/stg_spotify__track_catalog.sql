/*
================================================================================
 stg_spotify__track_catalog
--------------------------------------------------------------------------------
 Grain   : one row per track URI
 Source  : seeds/seed_track_catalog.csv
 Why     : Spotify's streaming history does NOT include track duration or
           genre. Duration is required for the ">= 90% played" rule, genre for
           session labelling. With real exports you can populate this seed
           from the Spotify Web API; if it is empty, downstream models fall
           back to the longest observed 'trackdone' play as the duration.
================================================================================
*/

select
    spotify_track_uri,
    trim(track_name)                     as track_name,
    trim(artist_name)                    as artist_name,
    trim(album_name)                     as album_name,
    coalesce(nullif(trim(genre), ''), 'Unknown Genre') as genre,
    duration_ms
from {{ ref('seed_track_catalog') }}
where spotify_track_uri is not null
qualify row_number() over (partition by spotify_track_uri order by track_name) = 1
