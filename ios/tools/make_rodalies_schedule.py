#!/usr/bin/env python3
"""Builds app/src/main/assets/rodalies_schedule.json, the iOS app's Rodalies
(Cercanías València) timetable, from Renfe's GTFS.

    curl -LO https://ssl.renfe.com/ftransit/Fichero_CER_FOMENTO/fomento_transit.zip
    unzip fomento_transit.zip -d gtfs
    python3 ios/tools/make_rodalies_schedule.py gtfs [YYYY-MM-DD]

Renfe's calendar is by date (about a month ahead), so one typical week is
taken: the 7 days starting on the given Monday (default: the first Monday
in the feed after today). Each departure keeps the days of that week it runs
on as a bit mask (bit 0 = Monday … bit 6 = Sunday); bank holidays can differ.
Stations are matched to rodalies.geojson by position, so names are the ones
the app shows. Entries: "HH:MM|line|destination|mask|last", last = 1 when the
train ends at that station (nobody boards).
"""
import csv, datetime, json, math, os, sys

GTFS = sys.argv[1]
ASSETS = os.path.join(os.path.dirname(__file__), "..", "..", "app", "src", "main", "assets")
VALENCIA = "40"  # Renfe's núcleo id: route ids start with it


def rows(name):
    with open(os.path.join(GTFS, name), newline="", encoding="utf-8-sig") as f:
        for row in csv.DictReader(f):
            yield {k.strip(): (v or "").strip() for k, v in row.items()}


def date(text):
    return datetime.date(int(text[:4]), int(text[4:6]), int(text[6:]))


def metres(a, b):
    dlat = math.radians(b[0] - a[0])
    dlon = math.radians(b[1] - a[1])
    h = math.sin(dlat / 2) ** 2 + math.cos(math.radians(a[0])) * math.cos(math.radians(b[0])) * math.sin(dlon / 2) ** 2
    return 2 * 6371000 * math.asin(math.sqrt(h))


routes = {r["route_id"]: r["route_short_name"] for r in rows("routes.txt") if r["route_id"].startswith(VALENCIA)}
trips = {t["trip_id"]: t for t in rows("trips.txt") if t["route_id"] in routes}
calendar = {c["service_id"]: c for c in rows("calendar.txt")}
weekdays = ("monday", "tuesday", "wednesday", "thursday", "friday", "saturday", "sunday")

if len(sys.argv) > 2:
    monday = datetime.date.fromisoformat(sys.argv[2])
else:
    first = min(date(calendar[t["service_id"]]["start_date"]) for t in trips.values() if t["service_id"] in calendar)
    start = max(first, datetime.date.today())
    monday = start + datetime.timedelta(days=(7 - start.weekday()) % 7)
week = [monday + datetime.timedelta(days=i) for i in range(7)]


def mask(service_id):
    c = calendar.get(service_id)
    if not c:
        return 0
    bits = 0
    for i, day in enumerate(week):
        if date(c["start_date"]) <= day <= date(c["end_date"]) and c[weekdays[day.weekday()]] == "1":
            bits |= 1 << i
    return bits


masks = {trip_id: mask(t["service_id"]) for trip_id, t in trips.items()}
trips = {k: v for k, v in trips.items() if masks[k]}

# Renfe stop id → the app's station name (nearest geojson station within 400 m).
with open(os.path.join(ASSETS, "rodalies.geojson"), encoding="utf-8") as f:
    stations = [(feat["properties"]["stop_name"], (feat["geometry"]["coordinates"][1], feat["geometry"]["coordinates"][0]))
                for feat in json.load(f)["features"] if feat["geometry"]["type"] == "Point" and feat["properties"].get("stop_name")]
names = {}
for stop in rows("stops.txt"):
    point = (float(stop["stop_lat"]), float(stop["stop_lon"]))
    name, distance = min(((n, metres(point, p)) for n, p in stations), key=lambda x: x[1])
    names[stop["stop_id"]] = name if distance <= 400 else stop["stop_name"]

calls = {}
for st in rows("stop_times.txt"):
    if st["trip_id"] in trips:
        calls.setdefault(st["trip_id"], []).append((int(st["stop_sequence"]), st["departure_time"] or st["arrival_time"], st["stop_id"]))

out = {}
for trip_id, stops in calls.items():
    stops.sort()
    line = routes[trips[trip_id]["route_id"]]
    destination = names.get(stops[-1][2], stops[-1][2])
    for index, (_, time, stop_id) in enumerate(stops):
        station = names.get(stop_id)
        if station is None or not time:
            continue
        key = (time[:5], line, destination, 1 if index == len(stops) - 1 else 0)
        entries = out.setdefault(station, {})
        entries[key] = entries.get(key, 0) | masks[trip_id]

result = {
    "source": f"Renfe GTFS (fomento_transit), week of {monday.isoformat()}",
    "stations": {
        station: [f"{t}|{line}|{dest}|{bits}|{last}" for (t, line, dest, last), bits in sorted(entries.items())]
        for station, entries in sorted(out.items())
    },
}
path = os.path.join(ASSETS, "rodalies_schedule.json")
with open(path, "w", encoding="utf-8") as f:
    json.dump(result, f, ensure_ascii=False, separators=(",", ":"))
known = {n for n, _ in stations}
print(f"{path}: {sum(len(v) for v in result['stations'].values())} departures at {len(result['stations'])} stations, "
      f"{len(known & set(result['stations']))}/{len(known)} app stations covered, week of {monday}")
