select
    calendar_date,
    sum(share_7d_pct) as total_share
from {{ ref('marts_listener_obsessions') }}
where total_7d_streams > 0
group by 1
having sum(share_7d_pct) > 100.1
