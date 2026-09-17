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
- Upload proxy: `http://localhost:8443` (presigned browser uploads only)

## Who may read the bucket

The `movies` bucket is **not** world-readable. The backend used to install an
"anyone may `GetObject`" policy when it created the bucket; it no longer
does, and the only anonymous read that should exist is the one **from the
cache server's own address** — every viewer goes through the cache, which
checks the signed token in each playback link (see
`../cacheserver/README.md`). The backend itself authenticates with its access
key and needs no anonymous grant at all.

Two ready-made policies live in `policies/`:

| file | allows anonymous `GetObject` from | use on |
|---|---|---|
| `movies-read-from-cache.json` | `213.111.155.181/32` (cache VPS) + a **placeholder** for the second cache server | production storage VPS |
| `movies-read-from-cache.local.json` | `127.0.0.1/32`, `172.16.0.0/12` (the local `cacheserver` container reaches MinIO through Docker's bridge) | this local rig |

Neither grants `ListBucket`, and neither lists the API VPS.

Both are also limited to the **prefixes the cache actually serves** — it is the
only anonymous reader, and it never fetches an archived master, a source PDF or
a staging object:

```
arn:aws:s3:::movies/images/*          posters, covers, avatars (public, unsigned)
arn:aws:s3:::movies/videos/*/hls/*    playlists, segments, subtitle renditions
arn:aws:s3:::movies/audio/*/hls/*     reserved; ships now so audio needs no policy change
arn:aws:s3:::movies/subtitles/*       uploaded subtitle sources (signed links)
arn:aws:s3:::movies/books/*           generated reader pages (signed links)
```

Everything else — `videos/<id>/original.*`, `audio/<id>/original.*`,
`documents/**` (book chapter PDFs) and `temp/**` — is read **only** by the
backend with its access key, so no anonymous grant covers it at all. That is a
second lock behind the cache server's deny map: even a request arriving from
the cache server's own address cannot fetch a master or a source PDF. See
`../docs/media-storage-layout.md` for what lives under each prefix.

Both files were bucket-wide until 2026-09-11, and neither had ever been applied
when they were narrowed, so nothing was migrated. **To roll back**, put this
statement back in place of the `Resource` list above (the `Condition` block
stays either way):

```json
"Resource": ["arn:aws:s3:::movies/*"],
```

> **Before applying the production file** replace
> `REPLACE_WITH_SECOND_CACHE_SERVER_IP` with the second cache server's public
> address (unknown at the time of writing) — or delete that array entry if
> there is only one cache server. `mc` rejects the placeholder as-is, which is
> intentional.

Apply with the MinIO client (`mc alias set remote http://<storage>:9000
<root-user> <root-password>` first):

```bash
mc anonymous set-json policies/movies-read-from-cache.json remote/movies
mc anonymous get-json remote/movies        # must show the aws:SourceIp condition
```

Locally: `mc anonymous set-json policies/movies-read-from-cache.local.json local/movies`.
On the local rig the `172.16.0.0/12` allowance means the local `:8443` proxy
still serves anonymous GETs to anything on the Docker network — acceptable on
a machine that is not on the internet, and exactly why the production file
has no such range. If local playback answers 403 after applying it, find the
address MinIO actually sees for the cache container (`mc admin trace local`
while requesting a segment — Docker Desktop on macOS can present
`192.168.65.0/24` for `host.docker.internal` traffic) and add that range.

`aws:SourceIp` is what makes this safe **only together with** the upload
proxy's header strip (`upload-proxy/templates/default.conf.template`): MinIO
reads the client address from `X-Forwarded-For` / `X-Real-IP` / `Forwarded`
before the socket address, so a proxy that forwarded those headers would let
anyone claim to be the cache server. The proxy now blanks all three.

## Rollout runbook (production storage VPS)

These steps close the direct-download path the QA report reproduced
(`HEAD :9000/movies/videos/<id>/original.mp4` → 200 from anywhere). They do
not depend on the cache/backend token rollout and can go first. Verify every
step with `curl` **from an outside address** (your own machine), never from
the command's exit code.

1. **Upload proxy: strip forwarded-IP headers.** Pull this repo's
   `upload-proxy/templates/default.conf.template`, then
   `docker compose up -d --force-recreate upload-proxy`. Presigned admin
   uploads must still succeed afterwards (upload any small poster from the
   admin app).
2. **Bucket policy.** Fill in the second cache address, then
   `mc anonymous set-json policies/movies-read-from-cache.json remote/movies`
   and read it back with `mc anonymous get-json remote/movies`.
3. **Firewall port 9000.** Docker publishes `:9000` around `ufw`, so the
   rule has to live in the `DOCKER-USER` chain. Only the cache VPS(es) and
   the API VPS (`185.165.169.16`) may reach it; `:8443` stays public. On the
   storage VPS (replace `eth0` with the public interface from `ip route`):

   ```bash
   # Drop first, then insert the allows ABOVE it (-I prepends).
   iptables -I DOCKER-USER -i eth0 -p tcp --dport 9000 -j DROP
   iptables -I DOCKER-USER -i eth0 -p tcp --dport 9000 -s 213.111.155.181 -j ACCEPT
   iptables -I DOCKER-USER -i eth0 -p tcp --dport 9000 -s 185.165.169.16 -j ACCEPT
   iptables -I DOCKER-USER -i eth0 -p tcp --dport 9000 -s <second-cache-ip> -j ACCEPT
   iptables -L DOCKER-USER -n --line-numbers
   netfilter-persistent save        # or iptables-save > /etc/iptables/rules.v4
   ```

   Matching on the public interface leaves container-to-container traffic
   (the upload proxy reaching `minio:9000` over the bridge) untouched.
4. **Verify from outside** (your Mac), with a real READY movie id:

   ```bash
   curl -sI --max-time 5 http://213.111.145.206:9000/movies/videos/<id>/hls/master.m3u8
   # -> timeout / connection refused (firewall). Before step 3: 403 AccessDenied (policy).
   curl -sI -H 'X-Forwarded-For: 213.111.155.181' http://213.111.145.206:8443/movies/videos/<id>/original.mp4
   # -> 403 (header stripped, address not in policy) — a 200 here means step 1 did not take.
   curl -sI http://213.111.145.206:8443/movies/images/movie/<uuid>.jpg
   # -> 403 as well: the proxy is for uploads; readers go through the cache.
   ```

   and from the cache VPS itself (`ssh` in), where the policy's prefix list is
   what is being proved — the first two must be **200**, the last three
   **403 AccessDenied** even though the address is allowed:

   ```bash
   curl -sI http://213.111.145.206:9000/movies/videos/<id>/hls/master.m3u8   # 200
   curl -sI http://213.111.145.206:9000/movies/images/movie/<uuid>.jpg       # 200
   curl -sI http://213.111.145.206:9000/movies/videos/<id>/original.mp4      # 403 — archived master
   curl -sI http://213.111.145.206:9000/movies/documents/books/<b>/<e>/<c>/original.pdf  # 403 — source PDF
   curl -sI http://213.111.145.206:9000/movies/temp/<session>/part-source.bin # 403 — staging
   ```

   A 200 on any of the last three means the bucket-wide policy is still
   applied. Finally play a title end to end through the website.
5. **Not done here, on purpose:** the upload proxy still forwards every HTTP
   method. Limiting it to `PUT`/`OPTIONS` is safe only once it is confirmed
   that the backend's production `MINIO_ENDPOINT` points at `:9000` and not
   at this proxy (multipart create/complete are `POST`, head/list are `GET`).
   Confirm that, then add `limit_except PUT OPTIONS { deny all; }` inside
   `location /`.

## Moving to a real VPS

Nothing changes except *where* this runs — same image, same compose file, on
the storage VPS instead of your machine — plus the bucket policy, header
strip and firewall above. Whatever reaches it (the cache server, the
backend's upload code) just needs to be pointed at that VPS's address instead
of `localhost`.
