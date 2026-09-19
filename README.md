# KERI infra (Phase 0 of the real-KERI migration)

This directory stands up the two Python services the app's identity layer
depends on once it migrates off the custom in-browser KERI-inspired scheme
(see `resources/Implementation Guide.md` for the system being replaced, and
`resources/KERI Migration - Phase 0 Findings.md` for what's been verified
about the replacement so far):

- **`keria`** — [KERIA](https://github.com/WebOfTrust/keria), the cloud
  agent the browser's `signify-ts` client talks to. It relays signed events
  to witnesses and coordinates multi-sig group operations; it never holds
  private key material (that's generated and held client-side by
  `signify-ts`, "signing at the edge").
- **`witness-demo`** — a pool of [keripy](https://github.com/WebOfTrust/keripy)
  witness nodes that receipt every key event.

## Running locally

```sh
docker compose -f infra/docker-compose.keri.yml up
```

- KERIA: boot `http://localhost:3901`, mailbox `http://localhost:3902`,
  admin `http://localhost:3903`.
- Witnesses: `http://localhost:5642`–`5647` (6 demo witnesses: wan, wil,
  wes, wit, wub, wyz).

These map to the app's env vars (see the app's env file, not tracked in
this repo):

```
KERIA_ADMIN_URL=http://localhost:3901
KERIA_BOOT_URL=http://localhost:3903
KERIA_HTTP_URL=http://localhost:3902
WITNESS_OOBIS=http://witness-demo:5642/oobi,http://witness-demo:5643/oobi,http://witness-demo:5644/oobi,http://witness-demo:5645/oobi,http://witness-demo:5646/oobi,http://witness-demo:5647/oobi
WITNESS_TOAD=3
```

`KERIA_*` use `localhost` because the browser/host talks to KERIA's published
ports directly. `WITNESS_OOBIS` must use the compose service hostname
(`witness-demo`), not `localhost` — a witness OOBI URL is never fetched by
the app itself; it's handed to KERIA via `client.oobis().resolve(oobi,
alias)`, and KERIA resolves it from *inside* the compose network, where
`localhost` means KERIA's own container. Confirmed empirically during the
Phase 0 spike (`scripts/keri-spike/incept-and-anchor.ts`): passing
`localhost` witness OOBIs made `oobis().resolve()` hang indefinitely with no
error (KERIA had nothing on its own port 5642 to even reject the request).

## ⚠️ `docker-compose.keri.yml` is dev-only — never point it at a real identity

`config/witness-demo/*.json` are keripy's own published **demo** witness
identities (aliases `wan`/`wes`/`wil`/`wit`/`wub`/`wyz`). Their signing keys
are public — anyone running this exact config has the same witnesses with
the same keys. That's fine for local development and the Phase 0 spike
(inception/rotation/receipt plumbing works identically regardless of whose
keys the witnesses hold), but it provides **zero real duplicity
protection** and must never receipt a real user identity. Use
`docker-compose.keri.prod.yml` (below) for anything that isn't local dev.

## Production stack: `docker-compose.keri.prod.yml`

```sh
npx tsx scripts/generate-keri-witness-keys.ts   # prints WITNESS_W1_BRAN..W6_BRAN — add to your prod .env
docker compose -f infra/docker-compose.keri.prod.yml up -d
```

Standalone file, not a `-f base -f prod` overlay on `docker-compose.keri.yml`
— Compose merges list-type keys (`ports`, `volumes`) across `-f` layers by
*concatenation*, not replacement, so an overlay can't actually remove the
dev file's host-published debug ports. Standalone avoids that trap.

What it does differently from the dev file, and why — all verified against
a live instance of this exact stack, not assumed:

1. **Fresh, independently-keyed witnesses** (`scripts/generate-keri-witness-
   keys.ts`, mirroring `scripts/generate-keri-service-bran.ts`'s
   `randomPasscode()`-based pattern) — `w1`..`w6`, replacing the public demo
   pool entirely. Confirmed live: `kli witness start --alias <alias>
   --passcode <bran>` incepts a real, independently-keyed witness AID from
   the passcode; each of the six comes up with a distinct AID.

   **Gotcha found and fixed while verifying this**: keripy's CLI silently
   strips `-` from a passcode when *re-opening* an existing witness keystore
   (though not on first inception) —
   `keripy/src/keri/app/cli/common/existing.py`: `bran =
   bran.replace("-", "")`. A bran containing `-` (which `signify-ts`'s own
   `randomPasscode()` can produce — it draws from the URL-safe base64
   alphabet) can incept a witness fine and then permanently fail to restart
   with `Bran (passcode seed material) too short` the moment the stripped
   string drops below keripy's 21-character minimum — a landmine that only
   detonates on the witness's first restart. Reproduced this exact failure
   live, then fixed it: `generate-keri-witness-keys.ts` generates from a
   plain alphanumeric alphabet instead of reusing `randomPasscode()`
   (`generate-keri-service-bran.ts`'s bran is unaffected — it's only ever
   consumed by `signify-ts` itself, which has no such stripping behavior).

2. **Widened to a full 6-witness pool** (kept at 6, not reduced to 5 — this
   is the exact topology the Phase 0 spike already validated end-to-end
   with `toad=3`; no reason to shrink a proven configuration). TOAD stays
   identity-level (`toad` kwarg on `client.identifiers().create()`), not a
   pool-wide config — unchanged from dev.
3. **Named volumes** — `keria-data` and `witness1-data`..`witness6-data`,
   each mounted at `/usr/local/var/keri` (confirmed live: this is exactly
   where both the KERIA agent and keripy witnesses keep their LMDB state —
   found via `find` inside a running container, not guessed). Verified
   durability directly: incepted all 6 witnesses, ran `docker compose down`
   (full container removal, not just `restart`) then `up` again, and
   confirmed every witness came back with the *same* AID — the state
   genuinely persisted on the volume, not just in a still-running process.
4. **Six separate containers** (`witness-1`..`witness-6`), not six processes
   in one — real restart/failure isolation per witness, each with its own
   volume.
5. **No public ports.** Witnesses are reachable only by `keria`, over the
   Docker-internal network — nothing about this app's own use of KERI
   requires the witness pool itself to be internet-reachable (that would
   only matter for a different, not-currently-needed goal: other operators'
   witness pools independently duplicity-checking this one). KERIA itself
   has no `ports:` either — see below.

### KERIA's public endpoint (nginx + certbot, in the stack)

`config/keria.json`'s `curls` (`http://keria:3902/`) is an internal Docker
hostname over plain HTTP — this is what KERIA advertises as its own
OOBI/curl, so it's the actual address a browser client or another KERI
agent resolves to reach this identity's KEL. It breaks the moment it isn't
`localhost` (browsers exempt `localhost` from mixed-content blocking; a
real public hostname is not exempt) and isn't reachable by anyone outside
the Docker network regardless.

`config/keria.prod.json` sets `curls` to `https://keria.arpradio.media/`
instead. `docker-compose.keri.prod.yml` runs `nginx` and `certbot` as part
of the same stack — nginx terminates TLS for the three `keria*.arpradio.media`
subdomains (`nginx/keria.conf`, the three server blocks for
mailbox/boot/admin) and reaches `keria` over the Compose network by service
name; certbot obtains and renews the certs nginx uses, dropped into a
shared `certbot-conf` volume. KERIA's raw ports 3901–3903 are never
published to the host — only nginx's 80/443 are, and only nginx (over the
Docker-internal network) reaches `keria` directly.

**First run only** — nginx's HTTPS server blocks reference certs that don't
exist yet, and certbot's webroot challenge needs nginx already up to serve
it, so bootstrap once before the normal `up -d`:

```sh
cd infra
LETSENCRYPT_EMAIL=you@example.com ./nginx/init-letsencrypt.sh
docker compose -f docker-compose.keri.prod.yml up -d   # bring up the witnesses too
```

(`LETSENCRYPT_EMAIL` can instead be set in `.env` — the script picks it up
from there if not exported. Add `LETSENCRYPT_STAGING=1` for a test run
against Let's Encrypt's staging environment first, to avoid burning its
production rate limits while iterating — staging certs are untrusted by
browsers, so re-run without it once the flow works.)

The script brings up `keria` and `nginx` itself partway through (it needs
nginx running to serve the ACME challenge); the witnesses aren't part of
that dependency chain, so the `up -d` after it is what actually starts
them — it's a no-op for the services the script already started. On
subsequent deploys (certs already issued), just `docker compose ... up -d`
brings everything up as-is — certbot's own renewal loop keeps certs current
from then on, no re-running the bootstrap script required unless the
`certbot-conf` volume is wiped.

DNS for all three `keria*.arpradio.media` subdomains must already point at
this host before running the bootstrap script — Let's Encrypt's HTTP-01
challenge needs to reach nginx on port 80 at each domain to issue the cert.

Env var split — browser-facing vars must be the public HTTPS URLs;
server-side vars can stay internal if the Next.js server shares the Docker
network (skips the public hop for the server's own KERIA calls):

```
# Browser-facing (signify-identity.ts) — must be public HTTPS:
NEXT_PUBLIC_KERIA_ADMIN_URL=https://keria-admin.arpradio.media
NEXT_PUBLIC_KERIA_BOOT_URL=https://keria-boot.arpradio.media

# Server-side (signify-service-client.ts) — can stay internal if the Next.js
# server and this compose stack share a Docker network:
KERIA_ADMIN_URL=http://keria:3901
KERIA_BOOT_URL=http://keria:3903
```

### Still genuinely undecided — operator decisions, not code

1. **Backup cadence.** No backup mechanism exists in this repo for Postgres
   either (it's external/operational) — there's nothing here to mirror.
   Whoever owns that process should snapshot the `keria-data` and
   `witness1-data`..`witness6-data` named volumes on the same
   cadence/retention as the Postgres backup, however that's actually
   implemented outside this repo.
2. **Hosting.** Something that can run this stack's 9 long-lived containers
   (keria, nginx, certbot, 6 witnesses) with persistent volume support and
   ports 80/443 reachable at whatever DNS points `keria*.arpradio.media`
   here. Not prescribed here since it's undecided — this repo has no
   existing container deploy to follow the pattern of.

## Schema hosting (ACDC / OOBI)

Real ACDC schemas must be resolvable by SAID over plain HTTP (an OOBI
target). Rather than a third container, the app hosts its own schemas at
`src/app/api/keri/schemas/[said]/route.ts` (see that file). Schema content
is immutable once a SAID has been referenced anywhere — a schema change is
always a new SAID served at a new URL, never an edit in place.
