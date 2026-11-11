/*
================================================================================
 marts_listener_obsessions
--------------------------------------------------------------------------------
 Grain   : one row per (calendar date x artist)  -- dense, zero-filled
 Purpose : Rolling 7-day and 30-day stream volumes, share-of-ear, momentum,
           and "obsession streak" detection per artist.
 Feeds   : outputs/mart_artist_obsessions.csv

 WHY THE DATE SPINE MATTERS
   A ROWS frame counts ROWS, not DAYS. If an artist has no streams on some
   days, `ROWS BETWEEN 6 PRECEDING AND CURRENT ROW` over sparse data silently
   spans more than 7 calendar days. We therefore cross-join a complete date
   spine with every artist and zero-fill, so exactly one row = one day and the
   ROWS frames are true 7-day / 30-day windows.

 Definitions
   stream            : music play with ms_played >= 30s (Spotify's own rule;
                       an instantly skipped track is not affinity)
   share_7d_pct      : artist's 7d streams / ALL artists' 7d streams
                       (denominator includes artists below the grid threshold)
   momentum_ratio    : 7d daily run-rate / 30d daily run-rate
                       > 1 = listening to this artist faster than usual
   is_obsessed       : 7d share AND 7d volume thresholds both met
   obsession_phase   : 'Rising' while momentum >= threshold (listening is
                       accelerating vs the artist's own 30d baseline),
                       'Sustained' once the obsession has plateaued
   obsession streak  : consecutive obsessed days (gaps-and-islands again)

 Scope: built for a single listener's export (the normal portfolio case).
 For multi-listener data, add listener_id to every PARTITION BY below.
================================================================================
*/

with

streams as (

    select
        event_date,
        artist_name
    from {{ ref('marts_fct_stream_events') }}
    where content_type = 'music'
      and is_qualified_stream

),

-- -----------------------------------------------------------------------------
-- 1. Daily counts (sparse: only days with streams exist here)
-- -----------------------------------------------------------------------------
daily_counts as (

    select
        event_date,
        artist_name,
        count(*)                                            as daily_streams
    from streams
    group by 1, 2

),

-- -----------------------------------------------------------------------------
-- 2. Complete calendar from first to last listening day
-- -----------------------------------------------------------------------------
date_spine as (

    select unnest(generate_series(min(event_date), max(event_date), interval 1 day))::date
                                                            as calendar_date
    from daily_counts

),

-- -----------------------------------------------------------------------------
-- 3. Denominators: ALL listening per day (every artist, however obscure),
--    rolled up over the same 7/30-day frames. Computed before any artist
--    filtering so share-of-ear stays honest.
-- -----------------------------------------------------------------------------
daily_totals as (

    select
        d.calendar_date,
        coalesce(sum(c.daily_streams), 0)                   as total_daily_streams
    from date_spine as d
    left join daily_counts as c
        on c.event_date = d.calendar_date
    group by 1

),

rolling_totals as (

    select
        calendar_date,
        total_daily_streams,
        sum(total_daily_streams) over (
            order by calendar_date rows between 6 preceding and current row
        )                                                   as total_7d_streams,
        sum(total_daily_streams) over (
            order by calendar_date rows between 29 preceding and current row
        )                                                   as total_30d_streams
    from daily_totals

),

-- -----------------------------------------------------------------------------
-- 4. Only artists with real lifetime volume get a dense daily grid.
--    (Real exports hold thousands of one-off artists: 2,000 artists x 2,700
--    days would be ~5M mostly-zero rows that can never be an obsession.)
-- -----------------------------------------------------------------------------
artists as (

    select
        artist_name,
        min(event_date)                                     as first_stream_date
    from daily_counts
    group by 1
    having sum(daily_streams) >= {{ var('obsession_min_lifetime_streams') }}

),

-- -----------------------------------------------------------------------------
-- 5. Dense grid: every eligible artist on every day from their FIRST stream
--    onwards, zero-filled. Days before discovery carry no information, and
--    the grid is still gap-free from that point, so ROWS frames == DAYS.
-- -----------------------------------------------------------------------------
dense_daily as (

    select
        d.calendar_date,
        a.artist_name,
        coalesce(c.daily_streams, 0)                        as daily_streams
    from artists as a
    inner join date_spine as d
        on d.calendar_date >= a.first_stream_date
    left join daily_counts as c
        on  c.event_date  = d.calendar_date
        and c.artist_name = a.artist_name

),

-- -----------------------------------------------------------------------------
-- 6. Rolling windows. Because the grid is dense, ROWS == DAYS.
-- -----------------------------------------------------------------------------
rolling as (

    select
        *,
        sum(daily_streams) over (
            partition by artist_name order by calendar_date
            rows between 6 preceding and current row
        )                                                   as rolling_7d_streams,
        sum(daily_streams) over (
            partition by artist_name order by calendar_date
            rows between 29 preceding and current row
        )                                                   as rolling_30d_streams,
        -- days since the artist's first stream (warm-up flag)
        row_number() over (
            partition by artist_name order by calendar_date
        )                                                   as days_of_history
    from dense_daily

),

-- -----------------------------------------------------------------------------
-- 7. Attach the all-artist denominators
-- -----------------------------------------------------------------------------
shares as (

    select
        r.*,
        t.total_daily_streams,
        t.total_7d_streams,
        t.total_30d_streams
    from rolling as r
    inner join rolling_totals as t
        using (calendar_date)

),

metrics as (

    select
        *,
        round(100.0 * daily_streams       / nullif(total_daily_streams, 0), 2) as share_daily_pct,
        round(100.0 * rolling_7d_streams  / nullif(total_7d_streams, 0), 2)    as share_7d_pct,
        round(100.0 * rolling_30d_streams / nullif(total_30d_streams, 0), 2)   as share_30d_pct,
        -- run-rates divide by the days actually in the window, so the first
        -- weeks of history aren't inflated by dividing a 3-day sum by 30
        round(
            (rolling_7d_streams / least(days_of_history, 7)::double)
            / nullif(rolling_30d_streams / least(days_of_history, 30)::double, 0)
        , 3)                                                as momentum_ratio_7d_vs_30d,
        days_of_history >= 7                                as is_full_7d_window,
        days_of_history >= 30                               as is_full_30d_window
    from shares

),

-- -----------------------------------------------------------------------------
-- 8. Obsession flag. Requires a full 7-day window so the first days of the
--    history don't produce spurious streaks.
-- -----------------------------------------------------------------------------
flagged as (

    select
        *,
        coalesce(
                is_full_7d_window
            and share_7d_pct             >= {{ var('obsession_min_share_7d_pct') }}
            and rolling_7d_streams       >= {{ var('obsession_min_streams_7d') }}
        , false)                                            as is_obsessed
    from metrics

),

-- -----------------------------------------------------------------------------
-- 9. Streaks = islands of consecutive obsessed days per artist.
--    Same cumulative-sum trick as sessionization: a streak starts on an
--    obsessed day whose previous day was not obsessed.
-- -----------------------------------------------------------------------------
streak_boundaries as (

    select
        *,
        case
            when is_obsessed
             and not coalesce(lag(is_obsessed) over (
                     partition by artist_name order by calendar_date), false)
            then 1 else 0
        end                                                 as is_streak_start
    from flagged

),

streak_numbered as (

    select
        *,
        sum(is_streak_start) over (
            partition by artist_name order by calendar_date
            rows between unbounded preceding and current row
        )                                                   as streak_number
    from streak_boundaries

)

select
    calendar_date,
    artist_name,
    daily_streams,
    rolling_7d_streams,
    rolling_30d_streams,
    total_daily_streams,
    total_7d_streams,
    share_daily_pct,
    share_7d_pct,
    share_30d_pct,
    momentum_ratio_7d_vs_30d,
    is_full_7d_window,
    is_full_30d_window,
    is_obsessed,

    case
        when not is_obsessed then null
        when momentum_ratio_7d_vs_30d >= {{ var('rising_momentum_ratio') }} then 'Rising'
        else 'Sustained'
    end                                                     as obsession_phase,

    case when is_obsessed
         then artist_name || ' #' || streak_number::varchar
    end                                                     as obsession_streak_id,

    case when is_obsessed
         then row_number() over (
                  partition by artist_name, streak_number, is_obsessed
                  order by calendar_date)
    end                                                     as obsession_streak_day,

    case when is_obsessed
         then count(*) over (partition by artist_name, streak_number, is_obsessed)
    end                                                     as obsession_streak_length_days,

    -- rank of the artist on the day by 7d volume (1 = top artist this week)
    dense_rank() over (
        partition by calendar_date order by rolling_7d_streams desc
    )                                                       as rank_7d

from streak_numbered
