# Real Spotify export (data/raw/Streaming_History_Audio_*.json):   make all
# Synthetic demo data (data/synthetic/endsong_*.json):             make synthetic
PY ?= python3
SYNTH_VARS = '{raw_streams_glob: "data/synthetic/endsong_*.json", obsession_min_lifetime_streams: 20}'

.PHONY: all build export synthetic data clean

all: build export                  ## real export -> dbt build -> CSVs

build:
	dbt build

export:
	$(PY) scripts/export_to_tableau.py

synthetic: data                    ## synthetic data -> dbt build -> CSVs
	dbt build --vars $(SYNTH_VARS)
	$(PY) scripts/export_to_tableau.py

data:
	$(PY) scripts/generate_synthetic_streams.py

clean:
	dbt clean
	rm -f spotify_analytics.duckdb outputs/*.csv outputs/_export_manifest.json
