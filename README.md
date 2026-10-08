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
- Upload proxy: `http://localhost:8443` (presigned browser uploads only: `PUT`/`POST`/`OPTIONS` under `movies/{videos,subtitles,temp,documents}/`, 403 for everything else)

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
| `movies-read-from-cache.local.json` | `192.168.65.0/24` + `172.19.0.1/32` (Docker Desktop's host side, or the storage network gateway after a restart, which is where MinIO sees the local `cacheserver` container coming from; see "Apply F-003 locally") | this local rig |

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

Locally, follow "Apply F-003 locally" below: it has the exact commands and
the checks.

`aws:SourceIp` is what makes this safe **only together with** the upload
proxy's header strip (`upload-proxy/templates/default.conf.template`): MinIO
reads the client address from `X-Forwarded-For` / `X-Real-IP` / `Forwarded`
before the socket address, so a proxy that forwarded those headers would let
anyone claim to be the cache server. The proxy now blanks all three. The
cache server blanks them too (`../cacheserver/nginx/templates/default.conf.template`),
for the opposite reason: nginx passes on whatever the viewer sent, so without
the blanks MinIO would judge a cache MISS by the viewer's header (or by one a
TLS proxy in front of the cache adds) instead of the cache's own address, and
refuse it.

## Apply F-003 locally (this Mac)

Status: **applied on 2026-09-29** (all 23 checks below passed). The local policy now allows two addresses: `192.168.65.0/24` and `172.19.0.1/32`. After a Mac/Docker restart on 2026-09-29, MinIO saw the cache (and every published-port client) as `172.19.0.1`, the gateway of the `storage-server_default` network, instead of `192.168.65.1`, and the cache got 403 on every miss. The upload proxy is still refused: it comes from its own container address (`172.19.0.3`). If `:8080` lines turn into 403 again after a Docker update or restart, find the address with `docker compose exec -T minio timeout 12 mc admin trace --verbose local` while requesting a missing key through the cache, and add it to the file. Rollback: apply `policies/movies-anonymous-read.before-2026-09-11.json` the same way.

Earlier note, 2026-09-28: **not applied.** The live policy is still the old
"anyone may read everything" one (`policies/movies-anonymous-read.before-2026-09-11.json`),
so `:9000` and `:8443` hand out originals, HLS, book PDFs and bank screenshots
to anyone on the Wi-Fi without a token.

**Why the local file allows `192.168.65.0/24` and nothing else.** Measured
with `mc admin trace` on this Mac: MinIO sees

| who asks | address MinIO sees |
|---|---|
| the cache container (via `host.docker.internal:9000`) | `192.168.65.1` |
| this Mac itself (`localhost:9000`) | `192.168.65.1` |
| this Mac's Wi-Fi address (`<mac-lan-ip>:9000`, what a phone would use) | `192.168.65.1` |
| the upload proxy (`:8443`, same compose network as MinIO) | `172.19.0.3` |

(The Wi-Fi row was measured from this Mac's own LAN address, not from a
second device; Docker Desktop on macOS does not keep the caller's address on
published ports, so a phone should look the same.)

The old local file allowed `172.16.0.0/12`, which contains the upload
proxy, so it would have left every `:8443` read open, and it did **not**
allow `192.168.65.x`, so it would have broken every image, video and book
page through the cache. Docker Desktop shows every published-port client as
the same address, so on this Mac the policy **cannot** tell the cache apart
from a Wi-Fi client on `:9000`. What it can do, and does:

- `:8443` (upload proxy): no anonymous read at all.
- `:9000` and the cache: originals (`videos/*/original.*`), `documents/**`
  (book PDFs, bank screenshots) and `temp/**` are refused for everyone.
- **Still open on `:9000` from the Wi-Fi** (not through the cache): images,
  HLS, subtitle sources and book pages, by key. Closing that needs `:9000`
  bound to this Mac only (`MINIO_API_PORT=127.0.0.1:9000` in `.env`, then
  recreate `minio`), which is the same kind of change as hiding `:9001` and
  Postgres `:5432` that was put off for now. Not done, and not tested here.
  Production does not have this gap: there the cache VPS has its own real
  address and `:9000` is firewalled (runbook below).

On a Linux Docker engine the addresses differ; measure them the same way
(`mc admin trace local` while fetching one image through the cache) before
using this file there.

Nothing below touches the database, the backend or any upload in progress.
Run it from the `MyanFlix` folder, in order:

```bash
# 1. Cache server: load the template that blanks the forwarded-IP headers
#    (also picks up restart: unless-stopped). Signed links keep working.
cd cacheserver
docker compose up -d --force-recreate cache
docker compose exec -T cache grep -c 'proxy_set_header X-Forwarded-For "";' /etc/nginx/conf.d/default.conf   # 1
cd ../storage-server

# 2. Upload proxy: must already blank the same headers (it does since
#    2026-09-11). If this prints 0: docker compose up -d --force-recreate upload-proxy
docker compose exec -T upload-proxy grep -c 'proxy_set_header X-Forwarded-For "";' /etc/nginx/conf.d/default.conf   # 1

# 3. Make sure mc inside the MinIO container is signed in with the root
#    user from this container's own environment (nothing is typed or shown).
docker compose exec -T minio sh -c 'mc alias set local http://localhost:9000 "$MINIO_ROOT_USER" "$MINIO_ROOT_PASSWORD"'

# 4. Confirm the live policy is the old open one, which is also the rollback
#    file (true on 2026-09-28). If diff prints anything instead, save that
#    output to a file first and use it for rollback.
docker compose exec -T minio mc anonymous get-json local/movies | diff - policies/movies-anonymous-read.before-2026-09-11.json && echo "same as the rollback file"

# 5. Apply the local policy.
docker compose cp policies/movies-read-from-cache.local.json minio:/tmp/f003-policy.json
docker compose exec -T minio mc anonymous set-json /tmp/f003-policy.json local/movies
docker compose exec -T minio mc anonymous get-json local/movies
# must show "aws:SourceIp":["192.168.65.0/24"] and exactly the five Resource
# prefixes (audio/*/hls/*, books/*, images/*, subtitles/*, videos/*/hls/*),
# never "arn:aws:s3:::movies/*"
```

Then check the effect, not the exit codes. This picks real keys from the
bucket and signs links the way the backend does (the secret is read from
`../cacheserver/.env` into a shell variable and never printed). It works in
zsh and bash:

```bash
cd storage-server
find_key() { docker compose exec -T minio mc find local/movies "$@" | head -1 | sed 's#^local/movies/##'; }
MASTER=$(find_key --name master.m3u8)
SEG=$(find_key --path "*${MASTER%/master.m3u8}/*" --name '*.ts')
ORIGINAL=$(find_key --name 'original.mp4')
PDF=$(find_key --path '*documents/books/*' --name original.pdf)
SHOT=$(find_key --path '*documents/bank-screenshots/*')
IMAGE=$(find_key --path '*images/*')
PAGE=$(find_key --path '*/pages/*' --name '*.webp')
SCOPE=$(printf '%s' "$MASTER" | sed -E 's#^(videos/[0-9a-f-]{36}/hls)/.*#\1#')
PSCOPE=$(printf '%s' "$PAGE" | sed -E 's#^(books/[^/]+/[^/]+/[^/]+/pages)/.*#\1#')
SECRET=$(grep '^STREAM_SIGNING_SECRET=' ../cacheserver/.env | cut -d= -f2-)
EXP=$(( $(date +%s) / 3600 * 3600 + 43200 ))
sign() { printf '%s %s %s' "$EXP" "$1" "$SECRET" | openssl md5 -binary | openssl base64 | tr '+/' '-_' | tr -d '='; }
LAN=$(ipconfig getifaddr en0 || ipconfig getifaddr en1)
NOPE=f003-probe-$(date +%s)   # a key that does not exist, so the cache cannot answer from its store
check() { want=$1; url=$2; shift 2; got=$(curl -s -o /dev/null -I --max-time 10 -w '%{http_code}' "$@" "$url"); [ "$got" = "$want" ] && r=ok || r=FAIL; echo "$r  got $got want $want  $url $*"; }

# Must STOP working (403) — no token, or not the cache:
check 403 "http://localhost:9000/movies/$ORIGINAL"
check 403 "http://$LAN:9000/movies/$ORIGINAL"
check 403 "http://localhost:9000/movies/$PDF"
check 403 "http://localhost:9000/movies/$SHOT"
check 403 "http://localhost:8443/movies/$MASTER"
check 403 "http://localhost:8443/movies/$SEG"
check 403 "http://localhost:8443/movies/$ORIGINAL"
check 403 "http://localhost:8443/movies/$SHOT"
check 403 "http://localhost:8443/movies/$IMAGE"
check 403 "http://localhost:8443/movies/$MASTER" -H 'X-Forwarded-For: 192.168.65.1'
check 403 "http://localhost:8080/movies/$MASTER"
check 403 "http://localhost:8080/movies/$ORIGINAL"
check 403 "http://localhost:8080/movies/$SHOT"

# Must KEEP working (200) — through the cache:
check 200 "http://localhost:8080/movies/$IMAGE"
check 200 "http://$LAN:8080/movies/$IMAGE"
check 200 "http://localhost:8080/s/$EXP/$(sign "$SCOPE")/movies/$MASTER"
check 200 "http://$LAN:8080/s/$EXP/$(sign "$SCOPE")/movies/$SEG"
check 200 "http://localhost:8080/s/$EXP/$(sign "$SCOPE")/movies/$SEG" -H 'X-Forwarded-For: 203.0.113.9'
check 200 "http://localhost:8080/s/$EXP/$(sign "$PSCOPE")/movies/$PAGE"

# What MinIO itself decides for the cache. Images and segments above may be
# answered from the cache's own store, so these ask for keys that do not
# exist: 404 = MinIO let the cache read and found nothing, 403 = MinIO
# refused the cache.
check 404 "http://localhost:8080/movies/images/actor/$NOPE.png"
check 404 "http://localhost:8080/s/$EXP/$(sign "$SCOPE")/movies/$SCOPE/$NOPE.ts"
check 404 "http://localhost:8080/s/$EXP/$(sign "$SCOPE")/movies/$SCOPE/$NOPE-x.ts" -H 'X-Forwarded-For: 203.0.113.9'
check 404 "http://localhost:8080/s/$EXP/$(sign "$PSCOPE")/movies/$PSCOPE/$NOPE.webp"

# Known gap on this Mac (see above), 200 after F-003 as well:
check 200 "http://$LAN:9000/movies/$MASTER"
```

Every line must start with `ok`. Before the policy is applied, the four
`:9000` lines and the six `:8443` lines print `FAIL got 200` — that is the
hole. A `:8080` line that turns into 403 after step 5 means MinIO sees the
cache from an address the policy does not list: find it with
`docker compose exec -T minio mc admin trace local` while repeating that
request, and fix the policy file, not the checks. If only the line with
`X-Forwarded-For: 203.0.113.9` fails, the cache is still running the old
template (step 1 did not take).

Then, by hand, the things only a person can see:

- Website and phone: posters load, a title plays and seeks, a subtitle shows,
  a book chapter opens.
- Admin: upload a small poster (presigned PUT through `:8443`), open a
  deposit's or withdrawal's bank screenshot (the backend streams it with its
  own key), and run "Check playback" on a title.

**Rollback** (puts the old, open policy back):

```bash
cd storage-server
docker compose cp policies/movies-anonymous-read.before-2026-09-11.json minio:/tmp/f003-rollback.json
docker compose exec -T minio mc anonymous set-json /tmp/f003-rollback.json local/movies
```

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
2. **Bucket policy.** First, on each cache VPS, pull `../cacheserver` and
   `docker compose up -d --force-recreate cache`: the current template blanks
   the viewer's forwarded-IP headers, and without that MinIO would judge a
   cache MISS by a viewer's `X-Forwarded-For` and refuse it. Then fill in the
   second cache address (or delete that entry if there is only one cache
   server; `mc` rejects the placeholder as-is), then
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
5. **Upload proxy: uploads only (done in the template, 2026-10-06, M-25).**
   `upload-proxy/templates/default.conf.template` now forwards only
   `PUT`/`POST`/`OPTIONS` under `/movies/{videos,subtitles,temp,documents}/`
   and answers **403 itself** for everything else (`/minio/health/*`,
   `/minio/admin/*`, the bucket root, `DELETE`, other buckets). The access
   log also records `$uri` instead of the full request line, so the signed
   query string (`X-Amz-Credential`, `X-Amz-Signature`) never lands in a
   log. Before pulling it on the storage VPS, confirm the backend's
   production `MINIO_ENDPOINT` points at `:9000` and **not** at this proxy:
   multipart create/complete, HEAD and LIST go backend→MinIO directly and
   would be refused here. Then `docker compose up -d --force-recreate
   upload-proxy` and check from outside (your Mac):

   ```bash
   S=213.111.145.206
   curl -s -o /dev/null -w '%{http_code}\n' http://$S:8443/minio/health/live        # 403 (was 200)
   curl -s -o /dev/null -w '%{http_code}\n' http://$S:8443/minio/admin/v3/info      # 403, no X-Amz-Request-Id
   curl -s -o /dev/null -w '%{http_code}\n' -X DELETE http://$S:8443/movies/temp/x  # 403 from nginx
   curl -s -o /dev/null -w '%{http_code}\n' http://$S:8443/movies/images/x.jpg      # 403
   curl -s -D - -o /dev/null -X PUT http://$S:8443/movies/temp/probe.txt | grep -i x-amz-request-id
   # -> an X-Amz-Request-Id line: the PUT reached MinIO (which refuses it unsigned, 403 AccessDenied)
   ```

   then upload a small poster and a subtitle from the admin app: both must
   still succeed. If a bucket or upload prefix is ever renamed, the
   `location ~ ^/movies/(...)/` line in the template is the one place to
   keep in step.

## Backend: stop using the MinIO root account (owner task, M-25)

Today `backend/.env` `MINIO_ACCESS_KEY` / `MINIO_SECRET_KEY` are the storage
server's `MINIO_ROOT_USER` / `MINIO_ROOT_PASSWORD`. Root can do anything on
MinIO, including the admin API (create users, rewrite the bucket policy,
delete the bucket), so one leaked `backend/.env` is the whole media store.
The backend only needs the S3 API on the `movies` bucket. Give it a
dedicated user with exactly that, and keep root for `mc` on the storage box.

Run on the **storage VPS** (or on this Mac for the local rig, with
`docker compose exec -T minio mc ...` instead of `mc ...` and `local`
instead of `remote`). Nothing below prints the root password. The new
user's secret is the one you generate in step 2: paste it straight into
`backend/.env`, never into a chat, a doc or a ticket.

```bash
# 0. mc signed in as root (one-time; same alias the policy steps above use).
mc alias set remote http://<storage>:9000 "$MINIO_ROOT_USER" "$MINIO_ROOT_PASSWORD"

# 1. A policy that is the S3 API on the movies bucket and nothing else
#    (no admin:*, no other bucket). s3:* on the bucket ARN covers what the
#    backend does on the bucket itself (HeadBucket/CreateBucket, PutBucketCors,
#    ListBucket, ListBucketMultipartUploads); s3:* on movies/* covers every
#    object call, multipart parts and presigning.
cat > /tmp/myanflix-backend-policy.json <<'POLICY'
{
  "Version": "2012-10-17",
  "Statement": [
    {
      "Effect": "Allow",
      "Action": ["s3:*"],
      "Resource": ["arn:aws:s3:::movies", "arn:aws:s3:::movies/*"]
    }
  ]
}
POLICY
mc admin policy create remote myanflix-backend /tmp/myanflix-backend-policy.json
rm /tmp/myanflix-backend-policy.json

# 2. The backend's own user. Generate the secret, keep it in your clipboard only.
SECRET="$(openssl rand -hex 24)"
mc admin user add remote myanflix-backend "$SECRET"
mc admin policy attach remote myanflix-backend --user myanflix-backend
mc admin user info remote myanflix-backend     # must show PolicyName: myanflix-backend, Status: enabled

# 3. Prove the new user is NOT an admin and CAN use the bucket (from your Mac
#    while :9000 is still reachable, or from the API VPS):
mc alias set check http://<storage>:9000 myanflix-backend "$SECRET"
mc admin info check                            # must FAIL with Access Denied
mc ls check/movies | head -3                   # must list objects
echo probe | mc pipe check/movies/temp/svc-probe.txt && mc rm check/movies/temp/svc-probe.txt   # must work
mc alias rm check
```

Then on the **API VPS**: set `MINIO_ACCESS_KEY=myanflix-backend` and
`MINIO_SECRET_KEY=<the secret>` in `backend/.env`,
`docker compose up -d --force-recreate backend`, and from the admin app
upload a poster, a subtitle and a chapter PDF, play one title, and open one
bank screenshot. All of these sign with the new user; if any fails with
`AccessDenied`, `mc admin user info remote myanflix-backend` is the first
thing to check. Finally rotate root (`MINIO_ROOT_PASSWORD` in
`storage-server/.env`, `docker compose up -d --force-recreate minio`),
since the old value lived on two VPSes for months. Until this is done, the
proxy change above already stops a leaked key from reaching the admin API
from the internet; it can still reach it from the API VPS on `:9000`, which
is why this step matters.

## Backups (media)

MinIO here runs on **one drive with no redundancy** (`mc admin info local`:
1 drive, erasure stripe size 1). Locally the objects live in the
`storage-server_minio-data` Docker volume, inside Docker Desktop's own disk
image: a Docker Desktop reset or a deleted volume loses every movie, book
and image. `scripts/minio-backup.sh` copies the bucket somewhere else with
`mc mirror` and then checks the copy against the bucket with `mc diff`
(a missing or stale object fails the run, whatever mc's exit code said).

```bash
cd storage-server
MINIO_BACKUP_TARGET=/Volumes/YOUR_SSD/myanflix-media bash scripts/minio-backup.sh
# → mirroring movies/ → /Volumes/YOUR_SSD/myanflix-media
# ✅ /Volumes/YOUR_SSD/myanflix-media matches the bucket (1544 objects in the copy)
```

- **Where to** (`MINIO_BACKUP_TARGET`, on the command line or in `.env`; the
  owner picks the place): an absolute folder on a **different disk** (an
  external SSD on the Mac, a second disk or mounted volume on the VPS), or
  another S3/MinIO as `<alias>/<bucket>` with
  `MC_HOST_<alias>=https://<access-key>:<secret-key>@<host>` next to it in
  `.env`. Keys land under the target exactly as in the bucket
  (`<target>/videos/<id>/hls/...`).
- **What:** everything except `temp/` (upload staging). That includes
  `documents/` (bank screenshots, book PDFs), so the target must be private.
  Nothing is ever deleted from the copy: a title removed by mistake can still
  be brought back. Clear old objects from the copy by hand if space matters.
- **How:** mc runs in a throwaway container made from the image the running
  `minio` service already uses (nothing to install or pull), inside that
  service's network, signed in with the root user from `.env`. Later runs
  copy only new or changed objects.
- **One prefix only:** `bash scripts/minio-backup.sh images` (or `books`,
  `videos/<id>`).

**Schedule it.**

- This Mac: `scripts/launchd/com.myanflix.minio-backup.plist` runs it daily
  at 04:00 (or at the next wake). It is in the repo, **not loaded**. Set
  `MINIO_BACKUP_TARGET` in `.env`, then:

  ```bash
  cp scripts/launchd/com.myanflix.minio-backup.plist ~/Library/LaunchAgents/
  launchctl bootstrap gui/$(id -u) ~/Library/LaunchAgents/com.myanflix.minio-backup.plist
  launchctl kickstart gui/$(id -u)/com.myanflix.minio-backup    # run once now
  tail ~/Library/Logs/myanflix-minio-backup.log                  # must end with ✅
  ```

  macOS blocks background jobs from reading `~/Desktop` (where this repo
  lives) and from writing to external drives until `/bin/bash` has **Full
  Disk Access** (System Settings > Privacy & Security > Full Disk Access, `+`,
  Cmd+Shift+G, `/bin/bash`). "Operation not permitted" in the log means
  exactly that. Remove the job with
  `launchctl bootout gui/$(id -u)/com.myanflix.minio-backup`.
- Storage VPS (`root`, `~/myanflix-storage-server`), daily at 03:30,
  `crontab -e`:

  ```cron
  30 3 * * * cd /root/myanflix-storage-server && flock -n /tmp/myanflix-minio-backup.lock bash scripts/minio-backup.sh >> /var/log/myanflix-minio-backup.log 2>&1
  ```

  Check the next morning: `tail /var/log/myanflix-minio-backup.log` ends
  with ✅.

**Restore.** The same mirror the other way round, into the running MinIO.
`--overwrite` replaces objects that exist but differ; nothing in the bucket
is deleted. One title (use the whole folder, `hls/` and `original.*`
together):

```bash
cd storage-server
set -a; . ./.env; set +a
export SRC_USER="${MINIO_ROOT_USER:-myanflix}" SRC_PASS="${MINIO_ROOT_PASSWORD:-change-me-locally}"
MINIO=$(docker compose ps -q minio)
FROM=/Volumes/YOUR_SSD/myanflix-media     # the MINIO_BACKUP_TARGET folder
KEY=videos/<movie-id>                      # or books/<book-id>, or images; KEY= (empty) = the whole bucket
docker run --rm --network "container:$MINIO" -e MC_CONFIG_DIR=/tmp/.mc -e SRC_USER -e SRC_PASS \
  -v "$FROM":/backup:ro --entrypoint sh "$(docker inspect -f '{{.Config.Image}}' "$MINIO")" -c \
  "mc alias set src http://localhost:9000 \"\$SRC_USER\" \"\$SRC_PASS\" >/dev/null && mc mirror --overwrite /backup/$KEY src/movies/$KEY && mc diff /backup/$KEY src/movies/$KEY"
```

`mc diff` printing nothing at the end means the bucket has every object of
that folder again. From an S3/MinIO target, drop the `-v` line, add
`-e MC_HOST_<alias>` and use `<alias>/<bucket>/$KEY` in place of
`/backup/$KEY`. Then play the title (or open the book) on the website.
Tested on 2026-09-28 against a spare MinIO: a full copy of this Mac's
bucket (1544 objects, 1.4 GiB) matched the bucket; restoring one title from
it (754 objects) gave a byte-identical `original.mp4`, and `KEY=` then
brought back the rest (1544 objects again).

**How much can be lost, how long it takes.** With the daily schedule, up to
one day of uploads (anything uploaded since the last run has to be uploaded
again). A restore takes as long as copying the data back: seconds for one
title from a local disk, longer over the network for the whole bucket.

## Moving to a real VPS

Nothing changes except *where* this runs — same image, same compose file, on
the storage VPS instead of your machine — plus the bucket policy, header
strip and firewall above. Whatever reaches it (the cache server, the
backend's upload code) just needs to be pointed at that VPS's address instead
of `localhost`.
