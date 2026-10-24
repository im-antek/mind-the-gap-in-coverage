-- 001_init.sql: initial schema for mind-the-gap-in-coverage.
--
-- Conventions:
--   * All timestamps are TEXT in UTC RFC3339 without fractional seconds,
--     e.g. '2026-10-24T07:16:00Z', so they sort and compare lexicographically.
--   * service_date is the London calendar date of the service day ('YYYY-MM-DD').
--     Times before 03:00 London belong to the previous service day.
--   * direction is TfL's 'inbound' / 'outbound' ('' when TfL does not say).
--   * Station ids are NaPTAN ids as used by TfL (e.g. '940GZZLUVXL').

-- ---------------------------------------------------------------------------
-- Reference data (refreshed weekly by cmd/timetable-sync)
-- ---------------------------------------------------------------------------

CREATE TABLE lines (
    line_id   TEXT PRIMARY KEY,          -- e.g. 'victoria', 'elizabeth', 'liberty'
    line_name TEXT NOT NULL,             -- e.g. 'Victoria'
    mode      TEXT NOT NULL              -- 'tube', 'dlr', 'overground', 'elizabeth-line', 'tram'
);

CREATE TABLE stations (
    naptan_id TEXT PRIMARY KEY,
    name      TEXT NOT NULL,
    lat       REAL,
    lon       REAL
);

-- Ordered stopping patterns per line and direction (from /Line/{id}/Route/Sequence).
-- Used to derive direction when a prediction does not carry one.
CREATE TABLE route_stops (
    line_id   TEXT    NOT NULL,
    direction TEXT    NOT NULL,
    route_idx INTEGER NOT NULL,          -- which ordered route of the line
    seq       INTEGER NOT NULL,          -- position along that route, 0-based
    naptan_id TEXT    NOT NULL,
    PRIMARY KEY (line_id, direction, route_idx, seq)
);

-- Scheduled side, part 1: when trains leave the origin station.
-- One row per timetabled departure from origin_naptan.
CREATE TABLE timetable_journeys (
    line_id       TEXT    NOT NULL,
    origin_naptan TEXT    NOT NULL,
    direction     TEXT    NOT NULL,
    schedule_name TEXT    NOT NULL,      -- e.g. 'Monday - Friday', 'Saturday', 'Sunday'
    dep_hour      INTEGER NOT NULL,      -- may be >= 24 for after-midnight departures
    dep_minute    INTEGER NOT NULL,
    interval_id   INTEGER NOT NULL       -- stopping pattern, see timetable_intervals
);
CREATE INDEX idx_timetable_journeys_line_schedule
    ON timetable_journeys (line_id, schedule_name);

-- Scheduled side, part 2: minutes from origin to each later stop, per stopping pattern.
-- scheduled arrival at a stop = journey departure + offset_minutes.
CREATE TABLE timetable_intervals (
    line_id        TEXT    NOT NULL,
    origin_naptan  TEXT    NOT NULL,
    direction      TEXT    NOT NULL,
    interval_id    INTEGER NOT NULL,
    seq            INTEGER NOT NULL,     -- a stop can appear twice (e.g. Circle line loop)
    naptan_id      TEXT    NOT NULL,
    offset_minutes REAL    NOT NULL,
    PRIMARY KEY (line_id, origin_naptan, direction, interval_id, seq)
);

-- ---------------------------------------------------------------------------
-- Live observations (written by cmd/poller, pruned after RAW_RETENTION_DAYS)
-- Live data for the API. Short-lived: do not rely on history beyond the retention window.
-- ---------------------------------------------------------------------------

-- One row per train trip approaching a station, updated on every poll.
CREATE TABLE vehicle_observations (
    service_date           TEXT    NOT NULL,
    line_id                TEXT    NOT NULL,
    naptan_id              TEXT    NOT NULL,
    direction              TEXT    NOT NULL,
    trip_key               TEXT    NOT NULL,  -- vehicle + first-seen marker, separates repeat visits
    line_name              TEXT    NOT NULL,
    mode                   TEXT    NOT NULL,
    station_name           TEXT    NOT NULL,
    platform               TEXT    NOT NULL DEFAULT '',
    vehicle_id             TEXT    NOT NULL DEFAULT '',
    destination            TEXT    NOT NULL DEFAULT '',
    first_seen_at          TEXT    NOT NULL,
    first_expected_arrival TEXT    NOT NULL,
    last_seen_at           TEXT    NOT NULL,
    last_expected_arrival  TEXT    NOT NULL,
    min_time_to_station    INTEGER NOT NULL,  -- seconds; <= 60 means the train arrived
    PRIMARY KEY (service_date, line_id, naptan_id, direction, trip_key)
);
CREATE INDEX idx_vehicle_observations_last_seen
    ON vehicle_observations (last_seen_at);

-- ---------------------------------------------------------------------------
-- Output (written by cmd/etl nightly) - THIS IS WHAT THE API READS
-- ---------------------------------------------------------------------------

-- One row per train arrival at a station, matched to its timetabled arrival.
CREATE TABLE arrivals (
    id                TEXT    PRIMARY KEY,  -- sha256 hex of line|naptan|direction|vehicle|scheduled_arrival
    service_date      TEXT    NOT NULL,
    line_id           TEXT    NOT NULL,
    line_name         TEXT    NOT NULL,
    mode              TEXT    NOT NULL,
    station_naptan    TEXT    NOT NULL,
    station_name      TEXT    NOT NULL,
    direction         TEXT    NOT NULL,
    platform          TEXT    NOT NULL DEFAULT '',
    vehicle_id        TEXT    NOT NULL DEFAULT '',
    destination       TEXT    NOT NULL DEFAULT '',
    scheduled_arrival TEXT    NOT NULL,
    actual_arrival    TEXT    NOT NULL,
    delay_seconds     INTEGER NOT NULL,     -- actual - scheduled; negative = early
    inserted_at       TEXT    NOT NULL
);
CREATE INDEX idx_arrivals_line_date    ON arrivals (line_id, service_date);
CREATE INDEX idx_arrivals_station_date ON arrivals (station_naptan, service_date);

-- Per-line ETL summary for each service day; useful for coverage / data-quality views.
CREATE TABLE etl_runs (
    service_date TEXT    NOT NULL,
    line_id      TEXT    NOT NULL,
    observed     INTEGER NOT NULL,          -- arrivals inferred from polling
    scheduled    INTEGER NOT NULL,          -- arrivals expected from the timetable
    matched      INTEGER NOT NULL,          -- rows written to arrivals
    run_at       TEXT    NOT NULL,
    PRIMARY KEY (service_date, line_id)
);
