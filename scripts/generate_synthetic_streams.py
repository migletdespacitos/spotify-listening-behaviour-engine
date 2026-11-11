from __future__ import annotations

import argparse
import csv
import json
import random
from dataclasses import dataclass
from datetime import datetime, timedelta, timezone
from pathlib import Path

CATALOG: dict[str, dict] = {
    "Neon Harbor": {"genre": "Synthwave", "album": "Midnight Transit", "tracks": [
        ("Coastline at 2AM", 241_000), ("Chrome Tides", 268_500), ("Afterglow Protocol", 302_000)]},
    "The Velvet Static": {"genre": "Indie Rock", "album": "Paper Satellites", "tracks": [
        ("Paper Satellites", 214_000), ("Static Bloom", 233_400), ("Northbound", 197_800)]},
    "Lumen Ayala": {"genre": "Pop", "album": "Glasshouse", "tracks": [
        ("Glasshouse", 188_200), ("Weightless", 203_700), ("Sundial", 176_900)]},
    "Kofi Marlowe": {"genre": "Hip-Hop", "album": "Concrete Psalms", "tracks": [
        ("Concrete Psalms", 222_000), ("Late Fees", 191_500)]},
    "Orchid Theory": {"genre": "Jazz", "album": "Blue Hour Sessions", "tracks": [
        ("Blue Hour", 327_000), ("Slow Rain Waltz", 289_300)]},
    "Saffron Circuit": {"genre": "Electronic", "album": "Monsoon Logic", "tracks": [
        ("Monsoon Logic", 256_800), ("Signal Garden", 274_100)]},
    "Hollow Pines": {"genre": "Folk", "album": "Kindling", "tracks": [
        ("Kindling", 209_600), ("River Ledger", 231_200)]},
    "Mara Okonkwo": {"genre": "R&B", "album": "Low Light", "tracks": [
        ("Low Light", 218_400), ("Gold Thread", 199_900), ("Honest Hours", 244_700)]},
}

PODCAST = {"show": "Data Engineering Weekly Pod", "episodes": [
    "Ep. 41 - Gaps and Islands Explained", "Ep. 42 - Why Your Window Frames Lie",
    "Ep. 43 - Modelling Sessions in SQL"]}

PLATFORMS = ["ios", "android", "osx", "windows", "web_player"]
PLATFORM_WEIGHTS = [0.45, 0.10, 0.25, 0.10, 0.10]

OCCASIONS = [
    ("commute_am", (7, 9), 9, "ios"),
    ("lunch", (12, 13), 6, "ios"),
    ("deep_work", (14, 17), 16, "osx"),
    ("evening", (19, 23), 12, None),
]
OCCASION_WEIGHTS = [0.25, 0.15, 0.25, 0.35]

LOCAL_UTC_OFFSET = timedelta(hours=8)


@dataclass
class Track:
    artist: str
    name: str
    album: str
    genre: str
    duration_ms: int
    uri: str


def build_tracks(rng):
    alphabet = "0123456789ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz"
    tracks = []
    for artist, meta in CATALOG.items():
        for name, dur in meta["tracks"]:
            uri = "spotify:track:" + "".join(rng.choice(alphabet) for _ in range(22))
            tracks.append(Track(artist, name, meta["album"], meta["genre"], dur, uri))
    return tracks


def phase_weights(day_idx, n_days, artists):
    phase_plan = [("Neon Harbor", "Orchid Theory"),
                  ("Lumen Ayala", "Kofi Marlowe"),
                  ("Saffron Circuit", "Mara Okonkwo"),
                  ("The Velvet Static", "Neon Harbor")]
    phase = min(int(day_idx / n_days * len(phase_plan)), len(phase_plan) - 1)
    obsessed, secondary = phase_plan[phase]
    weights = {a: 1.0 for a in artists}
    weights[obsessed] = 7.0
    weights[secondary] = 2.5
    return weights


def pick_track(rng, tracks, weights,
               previous):
    candidates = [t for t in tracks if previous is None or t.uri != previous.uri]
    w = [weights[t.artist] / len(CATALOG[t.artist]["tracks"]) for t in candidates]
    return rng.choices(candidates, weights=w, k=1)[0]


def play_outcome(rng, duration_ms, is_last):
    if is_last:
        reason = rng.choices(
            ["trackdone", "unexpected-exit-while-playing", "unexpected-exit", "endplay", "logout"],
            weights=[0.30, 0.30, 0.10, 0.20, 0.10])[0]
        if reason == "trackdone":
            return int(duration_ms * rng.uniform(0.985, 1.0)), reason
        return int(duration_ms * rng.uniform(0.05, 0.85)), reason

    roll = rng.random()
    if roll < 0.62:
        return int(duration_ms * rng.uniform(0.985, 1.0)), "trackdone"
    if roll < 0.84:
        return rng.randint(1_500, 29_000), "fwdbtn"
    if roll < 0.93:
        return int(duration_ms * rng.uniform(0.20, 0.80)), "fwdbtn"
    if roll < 0.97:
        return rng.randint(3_000, 60_000), "backbtn"
    return int(duration_ms * rng.uniform(0.10, 0.70)), "clickrow"


def iso_z(dt_utc):
    return dt_utc.strftime("%Y-%m-%dT%H:%M:%SZ")


def make_event(*, end_utc, ms_played, platform, track,
               episode, reason_start, reason_end, shuffle,
               username):
    return {
        "ts": iso_z(end_utc),
        "username": username,
        "platform": platform,
        "ms_played": ms_played,
        "conn_country": "SG",
        "master_metadata_track_name": track.name if track else None,
        "master_metadata_album_artist_name": track.artist if track else None,
        "master_metadata_album_album_name": track.album if track else None,
        "spotify_track_uri": track.uri if track else None,
        "episode_name": episode,
        "episode_show_name": PODCAST["show"] if episode else None,
        "spotify_episode_uri": (f"spotify:episode:pod{PODCAST['episodes'].index(episode):019d}"
                                if episode else None),
        "reason_start": reason_start,
        "reason_end": reason_end,
        "shuffle": shuffle,
        "skipped": reason_end == "fwdbtn",
        "offline": False,
        "offline_timestamp": None,
        "incognito_mode": False,
    }


def generate(n_events, start_date, n_days, seed,
             username):
    rng = random.Random(seed)
    tracks = build_tracks(rng)
    artists = list(CATALOG.keys())
    events: list[dict] = []

    avg_tracks_per_session = sum(o[2] * w for o, w in zip(OCCASIONS, OCCASION_WEIGHTS))
    sessions_per_day = n_events / (n_days * avg_tracks_per_session)

    day_idx = 0
    while len(events) < n_events:
        day = start_date + timedelta(days=day_idx)
        weights = phase_weights(min(day_idx, n_days - 1), n_days, artists)
        lam = sessions_per_day * (1.3 if day.weekday() >= 5 else 1.0)
        n_sessions = sum(1 for _ in range(6) if rng.random() < lam / 6)

        occasions = sorted(rng.choices(OCCASIONS, weights=OCCASION_WEIGHTS, k=n_sessions),
                           key=lambda o: o[1][0])
        last_session_end_local: datetime | None = None

        for _, (h_lo, h_hi), mean_tracks, platform_bias in occasions:
            start_local = day.replace(hour=rng.randint(h_lo, h_hi), minute=rng.randint(0, 59),
                                      second=rng.randint(0, 59))
            if last_session_end_local and start_local < last_session_end_local + timedelta(minutes=20):
                start_local = last_session_end_local + timedelta(minutes=rng.randint(20, 90))

            platform = platform_bias or rng.choices(PLATFORMS, weights=PLATFORM_WEIGHTS)[0]
            shuffle = rng.random() < 0.55
            n_tracks = max(1, int(rng.gauss(mean_tracks, mean_tracks * 0.4)))
            cursor = start_local
            prev_reason_end: str | None = None
            prev_track: Track | None = None

            for i in range(n_tracks):
                if len(events) >= n_events:
                    break
                is_last = i == n_tracks - 1
                reason_start = (rng.choices(["appload", "clickrow", "playbtn"], weights=[.5, .3, .2])[0]
                                if prev_reason_end is None else
                                prev_reason_end if prev_reason_end in ("trackdone", "fwdbtn", "backbtn")
                                else "clickrow")

                roll = rng.random()
                if roll < 0.03:
                    episode = rng.choice(PODCAST["episodes"])
                    ms_played = rng.randint(120_000, 1_500_000)
                    reason_end = "endplay" if is_last else "trackdone"
                    track = None
                elif roll < 0.04:
                    episode, track = None, None
                    ms_played, reason_end = rng.randint(0, 10_000), "trackerror"
                else:
                    episode = None
                    track = pick_track(rng, tracks, weights, prev_track)
                    ms_played, reason_end = play_outcome(rng, track.duration_ms, is_last)

                end_local = cursor + timedelta(milliseconds=ms_played)
                events.append(make_event(
                    end_utc=(end_local - LOCAL_UTC_OFFSET).replace(tzinfo=timezone.utc),
                    ms_played=ms_played, platform=platform, track=track, episode=episode,
                    reason_start=reason_start, reason_end=reason_end, shuffle=shuffle,
                    username=username))

                pause = rng.uniform(0.2, 3.0)
                if rng.random() < 0.06:
                    pause = rng.uniform(120, 780)
                cursor = end_local + timedelta(seconds=pause)
                prev_reason_end, prev_track = reason_end, track or prev_track

            last_session_end_local = cursor
        day_idx += 1

    for dup in rng.sample(events, k=min(4, len(events))):
        events.append(dict(dup))
    rng.shuffle(events)
    return events, tracks


def write_catalog(tracks, path):
    path.parent.mkdir(parents=True, exist_ok=True)
    with path.open("w", newline="", encoding="utf-8") as fh:
        w = csv.writer(fh)
        w.writerow(["spotify_track_uri", "track_name", "artist_name", "album_name", "genre", "duration_ms"])
        for t in tracks:
            w.writerow([t.uri, t.name, t.artist, t.album, t.genre, t.duration_ms])


def main():
    p = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    p.add_argument("--n-events", type=int, default=1000)
    p.add_argument("--days", type=int, default=90, help="Length of the listening window in days")
    p.add_argument("--start-date", default="2024-04-01", help="Local (SGT) start date, YYYY-MM-DD")
    p.add_argument("--seed", type=int, default=42)
    p.add_argument("--username", default="miko_listener")
    p.add_argument("--out", default="data/synthetic/endsong_0.json")
    p.add_argument("--catalog-out", default="seeds/seed_track_catalog.csv")
    args = p.parse_args()

    events, tracks = generate(args.n_events, datetime.fromisoformat(args.start_date),
                              args.days, args.seed, args.username)

    out = Path(args.out)
    out.parent.mkdir(parents=True, exist_ok=True)
    out.write_text(json.dumps(events, indent=2), encoding="utf-8")
    write_catalog(tracks, Path(args.catalog_out))

    n_null = sum(1 for e in events if e["master_metadata_track_name"] is None)
    print(f"Wrote {len(events):,} events -> {out}  ({n_null} with NULL track name, 4 duplicates)")
    print(f"Wrote {len(tracks)} tracks across {len(CATALOG)} artists -> {args.catalog_out}")


if __name__ == "__main__":
    main()
