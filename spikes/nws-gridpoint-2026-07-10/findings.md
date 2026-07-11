# NWS Gridpoint Live-Verification Spike

**Date**: 2026-07-10 (calls made ~2026-07-11T00:12-00:13 UTC / 2026-07-10 ~20:12-20:13 EDT)
**Purpose**: Prove the `wilted` briefing feature's NWS fetch chain resolves against the real
`api.weather.gov` for the ADR-fixed location (ZIP 20169, Haymarket VA).

**ADR-fixed facts under test**: office **LWX**, zone **VAZ526**, county **VAC153**.

All requests used:
```
-H 'User-Agent: wilted-radio/0.2 (david@cipherblade.com)'
-H 'Accept: application/geo+json'
```

No 403s were encountered on any call, so no User-Agent-missing diagnostic was needed — the
descriptive UA above was accepted by NWS on the first attempt for every endpoint.

---

## 1. ZIP 20169 -> lat/lon

Used the ADR-supplied centroid approximation **38.81,-77.64** (Haymarket, VA) per task instructions.
Not independently re-derived via a geocoder -- out of scope for this spike, the NWS chain resolution
is the point. This coordinate resolved to `relativeLocation.properties.city/state` = **"Haymarket, VA"**
with `distance.value: 0` in the points response below, which is a reasonable corroboration that the
point sits inside/at the town.

---

## 2. `GET https://api.weather.gov/points/38.81,-77.64`

**Status**: `200 OK`

Extracted fields:

| Field | Value |
|---|---|
| `properties.gridId` | **LWX** (matches ADR expectation) |
| `properties.gridX` | **76** |
| `properties.gridY` | **65** |
| `properties.forecast` | `https://api.weather.gov/gridpoints/LWX/76,65/forecast` |
| `properties.forecastGridData` | `https://api.weather.gov/gridpoints/LWX/76,65` |
| `properties.forecastZone` | `https://api.weather.gov/zones/forecast/VAZ526` (matches ADR) |
| `properties.county` | `https://api.weather.gov/zones/county/VAC153` (matches ADR) |
| `properties.timeZone` | `America/New_York` |
| `properties.relativeLocation.properties.city/state` | Haymarket, VA (distance 0m) |

Response headers of note:
- `cache-control: public, max-age=86400, s-maxage=120`
- `expires: Sun, 12 Jul 2026 00:12:56 GMT` (~24h out from request)
- No `X-Ratelimit-*` headers observed.

**Conclusion**: gridId/gridX/gridY/zone/county all match the ADR-fixed facts exactly. Point resolution
is stable and correct for this location.

---

## 3. `GET https://api.weather.gov/gridpoints/LWX/76,65/forecast`

**Status**: `200 OK`

Confirmed a real, live forecast payload -- 14 periods returned. First two:

| # | Name | Temp | Short Forecast |
|---|---|---|---|
| 1 | Tonight | 70F | Isolated Showers And Thunderstorms then Patchy Fog |
| 2 | Saturday | 85F | Patchy Fog then Chance Showers And Thunderstorms |

Other properties of note:
- `properties.generatedAt`: `2026-07-11T00:13:08+00:00` (i.e. this request's own generation timestamp)
- `properties.updateTime`: `2026-07-10T23:54:22+00:00` -- the underlying forecast package was last
  updated ~19 minutes before this fetch.
- `properties.validTimes`: `2026-07-10T17:00:00+00:00/P7DT8H` (~7-day forecast horizon)

Response headers of note:
- `last-modified: Fri, 10 Jul 2026 23:54:20 GMT` (matches `updateTime` above, within 2s)
- `etag` present (weak validator) -- usable for conditional GETs (`If-None-Match`) to avoid
  re-downloading unchanged forecasts.
- `cache-control: public, max-age=3600, s-maxage=3600` -- **1-hour cache lifetime**. This is the
  practical "update cadence" signal: polling more often than hourly gains nothing from NWS's own
  cache, and NWS forecast packages are typically regenerated a few times a day (roughly matches the
  ~19-minute-old `updateTime` seen here, well within a fresh cache window).
- `expires: Sat, 11 Jul 2026 01:13:08 GMT` (1h after `date`)
- No `X-Ratelimit-*` headers observed.

**Conclusion**: live, real forecast data confirmed for the resolved gridpoint.

---

## 4. `GET https://api.weather.gov/alerts/active?zone=VAZ526`

**Status**: `200 OK`

```json
{
    "type": "FeatureCollection",
    "features": [],
    "title": "Current watches, warnings, and advisories for Northwest Prince William (VAZ526) VA",
    "updated": "2026-07-11T00:13:12+00:00"
}
```

`features` is an empty array -- no active watches/warnings/advisories for VAZ526 at fetch time. This
is a valid, expected state (not an error) and confirms the endpoint is reachable and correctly scoped
to the ADR zone (title explicitly names "Northwest Prince William (VAZ526) VA").

**This is a separate surface from the gridpoint forecast** (step 3): `/alerts/active` is a
zone-scoped feed of NWS watches/warnings/advisories, entirely independent of the
`/gridpoints/{office}/{x,y}/forecast` periods payload. The briefing feature will need to hit both
endpoints separately -- one does not imply or embed the other.

Response headers of note:
- `cache-control: public, max-age=5, s-maxage=5` -- **only a 5-second cache lifetime**, dramatically
  shorter than the forecast's 1-hour cadence. This confirms alerts are meant to be polled much more
  frequently/near-real-time than the forecast if the briefing wants fresh alert status.
- `etag` present (weak validator), also usable for conditional GETs.
- No `X-Ratelimit-*` headers observed on any of the three endpoints hit in this spike.

---

## Summary / Success Criteria

- [x] Real forecast payload retrieved (14 periods, live `updateTime`/`generatedAt` timestamps).
- [x] Resolved gridpoint for office **LWX** recorded: **gridX=76, gridY=65**.
- [x] Active-alerts endpoint (`/alerts/active?zone=VAZ526`) confirmed reachable, 200, valid
      (empty) `features` array.
- [x] Cadence/rate-limit notes captured: forecast cache ~1h (`max-age=3600`), alerts cache ~5s
      (`max-age=5`), no `X-Ratelimit-*` headers exposed by NWS on any of these three endpoints.
- [x] Descriptive User-Agent (`wilted-radio/0.2 (david@cipherblade.com)`) worked on every call --
      no 403s encountered, so no diagnostic capture was necessary.

**Implication for the briefing feature**: the fetch chain (ZIP -> lat/lon -> `/points` -> `gridId`/
`gridX`/`gridY` -> `/gridpoints/.../forecast`) is fully live and resolves correctly end-to-end for
the ADR-fixed Haymarket VA location. Alerts should be fetched as a distinct, more-frequently-polled
call. A conditional-GET strategy using `etag`/`last-modified` would be a reasonable efficiency
follow-up when the real fetch code is built, given NWS explicitly returns both validators.
