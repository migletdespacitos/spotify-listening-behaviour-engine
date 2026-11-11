select *
from {{ ref('marts_listener_obsessions') }}
where rolling_30d_streams < rolling_7d_streams
