select
    stream_event_id,
    session_id,
    gap_from_prev_sec
from {{ ref('int_spotify__sessionized_events') }}
where is_session_start
  and gap_from_prev_sec is not null
  and gap_from_prev_sec <= {{ var('session_gap_seconds') }}
