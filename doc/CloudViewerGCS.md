# Cloud Viewer (GCS) - Additive to Existing Local Viewer

This adds a **Cloud** source to the existing TeslaUSB Viewer while keeping the current local file flow intact.

- `Local` source: existing behavior (`TeslaCam/` files local to runtime)
- `Cloud` source: files loaded from a Google Cloud Storage bucket via signed URLs
- Both sources can be switched in the same Viewer UI.

## What this does

- Keeps existing TeslaUSB local viewer capability.
- Adds optional cloud browsing/playback for archived clips in GCS.
- Supports running on a local computer via Docker Compose (not on-car Pi only).

## Prerequisites

- Docker + Docker Compose
- A local TeslaCam folder (for `Local` source), e.g.:
  - `RecentClips/...`
  - `SavedClips/...`
  - `SentryClips/...`
- Optional for cloud mode:
  - GCS bucket with TeslaCam-style paths
  - Service-account JSON key with permissions:
    - `storage.objects.list`
    - `storage.objects.get`

## Configure

1. Copy `.env.example` to `.env` and edit values.
2. If cloud mode is enabled, place service account key at:
   - `${GCS_CREDENTIALS_DIR}/gcs-service-account.json`
3. Ensure `LOCAL_TESLACAM_PATH` points to your local TeslaCam directory.

Example `.env` cloud settings:

```bash
GCS_BUCKET=my-teslacam-archive
GCS_PREFIX=TeslaCam
GCS_SIGN_TTL_SECONDS=900
GCS_CREDENTIALS_DIR=.
```

If your bucket stores `SavedClips/` and `SentryClips/` at bucket root (no `TeslaCam/` prefix), set:

```bash
GCS_PREFIX=
```

## Run

```bash
docker compose up --build
```

Open:

- `http://127.0.0.1:${CLOUD_VIEWER_PORT}` (default `18080`)

In Viewer tab, choose source from the new `Source` selector:

- `Local`
- `Cloud` (enabled only when cloud health check succeeds)

## API endpoints added

- `GET /api/v1/cloud/health`
- `GET /api/v1/cloud/videolist`
- `GET /api/v1/cloud/object-url?path=<relative>&download=0|1`
- `GET /api/v1/cloud/stream?path=<relative>&download=0|1`
- `GET /api/v1/local/config`
- `GET /api/v1/local/status`
- `GET /api/v1/local/videolist`

## Notes

- `Cloud` source is read-only.
- If cloud endpoint is unavailable, UI falls back to `Local`.
- Existing TeslaUSB Pi setup and `cgi-bin/videolist.sh` local path remain unchanged.
