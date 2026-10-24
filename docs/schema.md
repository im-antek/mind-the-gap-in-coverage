# Database schema

The backend writes a single SQLite file (`/data/mtg.db` in the cluster). The DDL lives in [`internal/store/migrations/001_init.sql`](../internal/store/migrations/001_init.sql); that file is the source of truth. Any change to it goes in a new numbered migration file, so the API can rely on the schema version.

## How to read it from the API

- The DB runs in **WAL mode**, so readers never block the writers. Open it **read-only**, e.g. with the `modernc.org/sqlite` DSN:
  `file:/data/mtg.db?mode=ro&_pragma=busy_timeout(5000)`.
- In k8s, mount the `mtg-data` PVC (namespace `mind-the-gap`) with `readOnly: true`. The cluster has a single node, so mounting the ReadWriteOnce volume works.
- `arrivals` and `etl_runs` land **once per night**, at about 02:30 London time, for the previous service day. Nothing for today shows up there until tomorrow.
- `vehicle_observations` is the live source, updated on every poll (about every 30s). Pruned after about 5 days.

## Formats

| Thing | Format | Example |
|---|---|---|
| Timestamps | UTC RFC3339 text, no fractional seconds | `2026-10-24T07:16:00Z` |
| `service_date` | London date of the service day; times before 03:00 count as the previous day | `2026-10-24` |
| `direction` | `inbound` / `outbound`, or `''` if TfL didn't provide it | `outbound` |
| Station ids | TfL NaPTAN ids | `940GZZLUVXL` (Vauxhall) |
| `mode` | `tube`, `dlr`, `overground`, `elizabeth-line`, `tram` | `tube` |

## Tables for the API

### `arrivals`: the main table
One row per train arriving at a station, matched to its timetabled arrival. Rows are never updated after insert.

| Column | Type | Notes |
|---|---|---|
| `id` | TEXT PK | Deterministic sha256 hash; stable across ETL re-runs |
| `service_date` | TEXT | |
| `line_id`, `line_name`, `mode` | TEXT | e.g. `victoria`, `Victoria`, `tube` |
| `station_naptan`, `station_name` | TEXT | |
| `direction` | TEXT | |
| `platform` | TEXT | e.g. `Southbound - Platform 2`, may be `''` |
| `vehicle_id` | TEXT | TfL train/set number, may be `''` |
| `destination` | TEXT | e.g. `Brixton Underground Station` |
| `scheduled_arrival` | TEXT | From the TfL timetable |
| `actual_arrival` | TEXT | Inferred from live predictions (see note below) |
| `delay_seconds` | INTEGER | `actual - scheduled`; negative = early |
| `inserted_at` | TEXT | When the ETL wrote the row |

Indexed on `(line_id, service_date)` and `(station_naptan, service_date)`.

Example queries:
```sql
-- average delay per line for a day
SELECT line_name, COUNT(*) AS trains, AVG(delay_seconds) AS avg_delay_s
FROM arrivals WHERE service_date = '2026-10-24'
GROUP BY line_name ORDER BY avg_delay_s DESC;

-- share of trains more than 2 minutes late at a station over a week
SELECT station_name, AVG(delay_seconds > 120) AS late_share
FROM arrivals
WHERE station_naptan = '940GZZLUVXL' AND service_date BETWEEN '2026-10-18' AND '2026-10-24'
GROUP BY station_name;
```

### `etl_runs`: data quality per line and day
| Column | Notes |
|---|---|
| `service_date`, `line_id` | PK |
| `observed` | Arrivals detected from live polling |
| `scheduled` | Arrivals expected by the timetable |
| `matched` | Rows written to `arrivals` |
| `run_at` | When the ETL ran |

`matched / scheduled` is a rough coverage figure. If it's low for a line, treat that line's numbers with care. Elizabeth line, Overground, DLR and tram timetables may be incomplete.

### Reference tables
- `lines(line_id, line_name, mode)`: all lines in scope.
- `stations(naptan_id, name, lat, lon)`: for maps and station pickers.
- `route_stops(line_id, direction, route_idx, seq, naptan_id)`: the ordered stops per line route. Useful for drawing a line diagram.

### `vehicle_observations`: live data
One row per train trip approaching a station, updated on every poll.

**Short-lived:** the poller deletes rows after about 5 days. Use this table for live data only. Use `arrivals` for history.

| Column | Type | Notes |
|---|---|---|
| `service_date`, `line_id`, `naptan_id`, `direction`, `trip_key` | TEXT | PK. `trip_key` is the vehicle plus a first-seen marker, so repeat visits stay separate |
| `line_name`, `mode`, `station_name` | TEXT | |
| `platform` | TEXT | May be `''` |
| `vehicle_id` | TEXT | May be `''` |
| `destination` | TEXT | May be `''` |
| `first_seen_at`, `last_seen_at` | TEXT | First and latest poll that saw this trip |
| `first_expected_arrival`, `last_expected_arrival` | TEXT | Predicted arrival at first and latest sighting |
| `min_time_to_station` | INTEGER | Seconds; `<= 60` means the train arrived |

Indexed on `(last_seen_at)`.

## Internal tables (do not build on these)
- `timetable_journeys`, `timetable_intervals`: the raw timetable, expanded by the ETL.

These can change shape without notice.

## Note on "actual" arrival
TfL has no "actual arrival" feed. The poller checks live predictions every 30s. When a train's prediction drops under 60s and it then leaves the board, `actual_arrival` is set to the last predicted arrival time. So the value is accurate to about ±30s, not to the second.
