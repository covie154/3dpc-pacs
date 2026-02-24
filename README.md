# 3dpc-pacs

Docker-based PACS server for a hospital 3D printing centre. Stores DICOM studies, provides OHIF-based viewing, supports attaching segmented STL models to studies, and issues passwordless share links so studies can be sent to surgeons or technicians without giving them an account.

## Architecture

```
Internet
  │
  ├─ :443 HTTPS ─→ nginx ─→ orthanc :8042              (staff, logged in)
  │                       ─→ orthanc-for-shares :8042   (share links, JWT-gated)
  ├─ :80  HTTP  ─→ nginx (ACME challenge + redirect)
  └─ :4242 DICOM ─→ orthanc :4242                       (scanners, no auth)

Internal only:
  orthanc ↔ orthanc-auth-service :8000
  orthanc-for-shares ↔ orthanc-auth-service :8000
```

Two Orthanc instances share the same storage volume. The main instance handles authenticated staff access and issues share tokens; the shares instance validates those tokens and serves anonymous share link access.

## Services

| Service | Image | Role |
|---|---|---|
| `nginx` | `orthancteam/orthanc-nginx:current` | HTTPS reverse proxy, ACME challenge |
| `certbot` | `certbot/certbot:latest` | Let's Encrypt cert issuance/renewal |
| `orthanc` | `orthancteam/orthanc:current` | Main PACS (OHIF + STL + OE2 + auth) |
| `orthanc-for-shares` | `orthancteam/orthanc:current` | Anonymous share access |
| `orthanc-auth-service` | `orthancteam/orthanc-auth-service:current` | Token issue + validation |

## File Structure

```
3dpc-pacs/
├── docker-compose.yml
├── .env                          # never commit — copy from .env.example
├── .env.example
├── .gitignore
├── config/
│   ├── orthanc/
│   │   └── orthanc.json          # main instance config
│   ├── orthanc-shares/
│   │   └── orthanc.json          # shares instance config
│   └── auth-service/
│       └── permissions.json      # role/permission definitions
└── scripts/
    └── init-cert.sh              # one-time Let's Encrypt bootstrap
```

## Prerequisites

- Linux server with a public IP
- Docker with Compose v2 (`docker compose version`)
- A domain name with an A record pointing to the server's IP
- Ports 80, 443, and 4242 open in any firewall/security group

## Deployment

### 1. Configure

```bash
cp .env.example .env
```

Edit `.env` and fill in all values. Generate the JWT signing key:

```bash
openssl rand -hex 64
```

### 2. Bootstrap TLS (one-time)

```bash
bash scripts/init-cert.sh
```

This starts nginx in HTTP-only mode, obtains a Let's Encrypt certificate via the ACME webroot challenge, then stops. Run `docker compose up -d` afterward to start the full HTTPS stack.

### 3. Start

```bash
docker compose up -d
docker compose ps        # confirm all 5 containers running
docker compose logs -f   # watch for errors
```

### 4. Verify

```bash
# Web UI — should return 401 without credentials
curl -s -o /dev/null -w "%{http_code}" https://YOUR_DOMAIN/orthanc/

# Plugin list — confirm stl, ohif, dicom-web, authorization, orthanc-explorer-2
curl -u admin:PASSWORD https://YOUR_DOMAIN/orthanc/plugins

# DICOM connectivity (requires dcmtk)
echoscu -aec 3DPCPACS YOUR_DOMAIN 4242
```

### 5. Set up cert renewal

Add to the host's crontab (`crontab -e`):

```
0 3 1,15 * * cd /path/to/3dpc-pacs && docker compose run --rm certbot renew --quiet && docker compose exec nginx nginx -s reload
```

Test without renewing:

```bash
docker compose run --rm certbot renew --dry-run
```

## Local/LAN Testing (no public domain)

Set `ENABLE_HTTPS: "false"` on the nginx service in `docker-compose.yml` and use the machine's LAN IP in `.env`:

```dotenv
DOMAIN=192.168.1.205
PUBLIC_ORTHANC_ROOT=http://192.168.1.205/shares/
PUBLIC_LANDING_ROOT=http://192.168.1.205/shares/ui/app/token-landing.html
PUBLIC_OHIF_ROOT=http://192.168.1.205/ohif/
```

Skip `init-cert.sh` and run `docker compose up -d` directly.

## Firewall Ports

| Port | Protocol | Purpose |
|------|----------|---------|
| 80 | TCP | ACME challenge + HTTP→HTTPS redirect |
| 443 | TCP | HTTPS — staff UI and share links |
| 4242 | TCP | DICOM — scanners and workstations |

## Attaching STL Models to Studies

**Via OE2 UI:** The STL plugin adds an "Attach STL model" button to the study view automatically.

**Via REST API:**

```bash
curl -u admin:PASSWORD -X POST https://YOUR_DOMAIN/orthanc/tools/create-dicom \
  -H "Content-Type: application/json" \
  -d '{
    "Tags": {
      "StudyInstanceUID": "1.2.3...",
      "Modality": "M3D"
    },
    "Content": "data:model/stl;base64,<base64-encoded-stl>"
  }'
```

Note: multipart form upload is not supported — use the JSON + Base64 pattern above.

## Share Links

1. Open a study in OE2
2. Click **Share** and select an expiry duration (0 = no expiry)
3. Copy the generated link — it opens the study in OHIF without requiring a login
4. Tokens are scoped to the specific study; they cannot be used to access other studies

## Secrets

| Secret | Purpose |
|---|---|
| `ORTHANC_ADMIN_PASSWORD` | Staff login to OE2 and REST API |
| `AUTH_SERVICE_WEB_PASSWORD` | HTTP Basic Auth between Orthanc and auth-service |
| `AUTH_SERVICE_SECRET_KEY` | JWT signing key — never put this in orthanc.json |

`.env` is listed in `.gitignore` and must never be committed.

## Known Limitations

- **SQLite concurrency:** Both Orthanc instances write to the same SQLite file. Concurrent writes under heavy load may produce `SQLITE_BUSY` errors. Replace with PostgreSQL (`ORTHANC__POSTGRESQL__*` env vars) if this becomes a problem.
- **DICOM port is unauthenticated:** Standard DICOM has no strong auth mechanism. Restrict access by IP at the firewall level, or enable `DicomCheckCalledAet` and whitelist AE titles in `config/orthanc/orthanc.json`.

## Future Work

- **PostgreSQL** — replace SQLite for production concurrent access
- **Keycloak SSO** — drop-in replacement for standalone auth-service user management
- **NIfTI/NRRD upload** — `EnableNIfTI: true` already handles NIfTI→STL conversion; NRRD requires a pre-upload conversion step
