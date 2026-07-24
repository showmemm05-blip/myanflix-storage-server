# Storage server (local test rig)

Local stand-in for the **Movie Storage Server** from the architecture
diagram — a MinIO instance, run entirely on its own. This is a separate
server from the cache server (`../cacheserver`) and from the app backend
(`../backend`), matching the real deployment where each role is its own VPS.

## Run it

```bash
cd storage-server
cp .env.example .env
docker compose up -d
```

- MinIO API: `http://localhost:9000` (S3-compatible)
- MinIO console: `http://localhost:9001` (log in with the credentials from `.env`)

## Moving to a real VPS

Nothing changes except *where* this runs — same image, same compose file, on
the storage VPS instead of your machine. Whatever reaches it (the cache
server, or later the backend's upload code) just needs to be pointed at that
VPS's address instead of `localhost`.
