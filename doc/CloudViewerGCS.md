# Cloud Viewer (GCS + S3) - Additive to Existing Local Viewer

This adds optional cloud sources to the existing TeslaUSB Viewer while keeping the current local file flow intact.

- `Local` source: existing behavior (`TeslaCam/` files local to runtime)
- `GCS` source: files loaded from Google Cloud Storage via signed URLs
- `S3` source: files loaded from Amazon S3 (or S3-compatible endpoint) via presigned URLs
- Source selector is shown only when cloud storage is configured.

## What this does

- Keeps existing TeslaUSB local viewer capability.
- Adds optional GCS/S3 browsing and playback for archived clips.
- Supports running on a local computer via Docker Compose (not on-car Pi only).

## Prerequisites

- Docker + Docker Compose
- A local TeslaCam folder (for `Local` source), e.g.:
  - `RecentClips/...`
  - `SavedClips/...`
  - `SentryClips/...`
- Optional for cloud mode:
  - GCS bucket with TeslaCam-style paths, or S3 bucket with TeslaCam-style paths
  - For GCS:
    - Service-account JSON key with:
      - `storage.objects.list`
      - `storage.objects.get`
  - For S3:
    - Credentials with `s3:ListBucket` and `s3:GetObject` (or equivalent for your S3-compatible provider)

## Configure

1. Copy `.env.example` to `.env` and edit values.
2. Configure one or both cloud providers.
3. If using GCS, place service account key at:
   - `${GCS_CREDENTIALS_DIR}/gcs-service-account.json`
4. If using S3, set region and credentials in `.env` (or use default AWS credential chain).
5. Set optional default provider:
   - `CLOUD_PROVIDER=gcs` or `CLOUD_PROVIDER=s3`
   - Used when API requests omit `provider=` (legacy compatibility).
6. Ensure `LOCAL_TESLACAM_PATH` points to your local TeslaCam directory.

Example `.env` for GCS:

```bash
CLOUD_PROVIDER=gcs
GCS_BUCKET=my-teslacam-archive
GCS_PREFIX=TeslaCam
GCS_SIGN_TTL_SECONDS=900
GCS_CREDENTIALS_DIR=.
```

If your GCS bucket stores `SavedClips/` and `SentryClips/` at bucket root (no `TeslaCam/` prefix), set:

```bash
GCS_PREFIX=
```

Example `.env` for S3:

```bash
CLOUD_PROVIDER=s3
S3_BUCKET=my-teslacam-archive
S3_PREFIX=TeslaCam
S3_REGION=us-east-1
S3_SIGN_TTL_SECONDS=900
AWS_ACCESS_KEY_ID=...
AWS_SECRET_ACCESS_KEY=...
```

For S3-compatible endpoints (for example MinIO), set `S3_ENDPOINT` and optionally `S3_FORCE_PATH_STYLE=true`.

If your S3 bucket stores clips at bucket root (no `TeslaCam/` prefix), set:

```bash
S3_PREFIX=
```

To disable cloud source entirely:

```bash
GCS_BUCKET=
S3_BUCKET=
```

If both `GCS_BUCKET` and `S3_BUCKET` are configured, both sources are shown in the viewer (`Local`, `GCS`, `S3`).

## Run

```bash
docker compose up --build
```

Open:

- `http://127.0.0.1:${CLOUD_VIEWER_PORT}` (default `18080`)

In Viewer tab, choose source from the `Source` selector (shown only when cloud is configured):

- `Local`
- `GCS` or `S3` (based on configured provider)

## API endpoints added

- `GET /api/v1/cloud/health`
- `GET /api/v1/cloud/videolist?provider=gcs|s3` (`provider` optional; defaults to `CLOUD_PROVIDER` or first configured provider)
- `GET /api/v1/cloud/object-url?provider=gcs|s3&path=<relative>&download=0|1`
- `GET /api/v1/cloud/stream?provider=gcs|s3&path=<relative>&download=0|1`
- `GET /api/v1/local/config`
- `GET /api/v1/local/status`
- `GET /api/v1/local/videolist`

## Notes

- Cloud sources are read-only.
- If cloud endpoint is unavailable, UI falls back to `Local`.
- Existing TeslaUSB Pi setup and `cgi-bin/videolist.sh` local path remain unchanged.
