from __future__ import annotations

import argparse
import json
import subprocess
import sys
from datetime import datetime, timezone
from pathlib import Path

import duckdb

PROJECT_ROOT = Path(__file__).resolve().parents[1]

EXPORTS: dict[str, tuple[str, list[str]]] = {

    "dim_listening_sessions.csv": ("""
        -- Session-level dimension (grain: session_id)
        select
            -- requested columns
            session_id,
            session_start_ts,
            session_end_ts,
            total_tracks_played,
            total_duration_minutes,
            primary_genre_or_artist,
            -- analysis extras
            session_date,
            session_start_hour,
            session_day_of_week,
            session_day_of_week_num,
            session_span_minutes,
            session_length_bucket,
            primary_artist,
            primary_genre,
            unique_tracks,
            unique_artists,
            complete_listens,
            explicit_skips,
            partial_listens,
            background_exits,
            completion_rate_pct,
            explicit_skip_rate_pct,
            session_end_reason,
            used_shuffle,
            primary_platform
        from marts.marts_dim_listening_sessions
        order by session_start_ts
    """, ["session_id"]),

    "fact_stream_events.csv": ("""
        -- Event-level fact (grain: stream_event_id)
        select
            -- requested columns
            stream_start_ts            as "timestamp",
            session_id,
            artist_name,
            track_name,
            duration_played_sec,
            skip_type,
            hour_of_day,
            day_of_week,
            -- analysis extras
            stream_event_id,
            stream_end_ts,
            event_date,
            day_of_week_num,           -- sort key for day_of_week in Tableau
            day_type,
            daypart,
            event_seq_in_session,
            content_type,
            album_name,
            genre,
            track_duration_sec,
            pct_played,
            is_explicit_skip,
            is_any_skip,
            is_complete_listen,
            is_qualified_stream,
            reason_start,
            reason_end,
            platform,
            is_shuffle
        from marts.marts_fct_stream_events
        order by stream_start_ts
    """, ["stream_event_id"]),

    "mart_artist_obsessions.csv": ("""
        -- Dense daily time series (grain: date x artist_name)
        select
            -- requested columns
            calendar_date                  as "date",
            artist_name,
            rolling_7d_streams             as "7d_rolling_streams",
            rolling_30d_streams            as "30d_rolling_streams",
            share_7d_pct                   as share_of_total_listens_pct,
            -- analysis extras
            daily_streams,
            share_daily_pct,
            share_30d_pct,
            momentum_ratio_7d_vs_30d,
            rank_7d,
            is_full_7d_window,
            is_full_30d_window,
            is_obsessed,
            obsession_phase,
            obsession_streak_id,
            obsession_streak_day,
            obsession_streak_length_days
        from marts.marts_listener_obsessions
        order by calendar_date, artist_name
    """, ["date", "artist_name"]),
}


def run_dbt():
    print("▶ dbt build ...")
    result = subprocess.run(["dbt", "build"], cwd=PROJECT_ROOT)
    if result.returncode != 0:
        sys.exit("✖ dbt build failed — fix the failing models/tests before exporting.")


def export_one(con, sql, keys, path):
    rel = con.sql(sql)
    n_rows = con.execute(f"select count(*) from ({sql})").fetchall()[0][0]
    if n_rows == 0:
        raise ValueError(f"{path.name}: query returned 0 rows")
    key_list = ", ".join(f'"{k}"' for k in keys)
    dupes = con.execute(
        f"select count(*) from (select {key_list} from ({sql}) group by all having count(*) > 1)"
    ).fetchall()[0][0]
    if dupes:
        raise ValueError(f"{path.name}: {dupes} duplicate keys on grain {keys}")

    con.execute(f"""
        copy ({sql}) to '{path.as_posix()}' (
            format csv,
            header true,
            delimiter ',',
            timestampformat '%Y-%m-%d %H:%M:%S',
            dateformat '%Y-%m-%d'
        )
    """)
    return {"file": path.name, "rows": n_rows, "grain": keys, "columns": rel.columns}


def main():
    p = argparse.ArgumentParser(description="Export dbt marts to Tableau-ready CSVs.")
    p.add_argument("--db", default=str(PROJECT_ROOT / "spotify_analytics.duckdb"))
    p.add_argument("--out-dir", default=str(PROJECT_ROOT / "outputs"))
    p.add_argument("--run-dbt", action="store_true", help="Run `dbt build` before exporting")
    args = p.parse_args()

    if args.run_dbt:
        run_dbt()

    db_path, out_dir = Path(args.db), Path(args.out_dir)
    if not db_path.exists():
        sys.exit(f"✖ {db_path} not found — run `dbt build` first (or pass --run-dbt).")
    out_dir.mkdir(parents=True, exist_ok=True)

    manifest = {"generated_at_utc": datetime.now(timezone.utc).isoformat(timespec="seconds"),
                "source_db": db_path.name, "exports": []}

    with duckdb.connect(str(db_path), read_only=True) as con:
        for file_name, (sql, keys) in EXPORTS.items():
            info = export_one(con, sql, keys, out_dir / file_name)
            manifest["exports"].append(info)
            print(f"✔ {file_name:<28} {info['rows']:>6,} rows  {len(info['columns'])} cols")

    (out_dir / "_export_manifest.json").write_text(json.dumps(manifest, indent=2))
    print(f"\nAll exports written to {out_dir}/ — connect Tableau Public via Text File.")


if __name__ == "__main__":
    main()
