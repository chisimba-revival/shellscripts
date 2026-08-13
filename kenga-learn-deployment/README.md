# Kenga Learn production deployment

This directory records the initial deployment of the PHP 8.5.4 Chisimba
runtime for Kenga Learn. It contains the scripts used to prepare the Ubuntu
host, assemble and deploy the application, and repair one permission problem
found during the first deployment.

The production application is served at the web root:

```text
https://104.248.35.30/
https://kengalearn.com/    (after DNS and trusted TLS are configured)
```

There is deliberately no `/ch/` component in the production URL.

## Current host

The first production host was created at DigitalOcean with these details:

| Item | Value |
| --- | --- |
| Droplet | `kengalearn-prod-01-fra1` |
| Region | Frankfurt (`fra1`) |
| Operating system | Ubuntu 26.04 LTS |
| IPv4 | `104.248.35.30` |
| IPv6 | `2a03:b0c0:3:f0:0:2:cdb1:7000` |
| Compute | 2 vCPU, 2 GB RAM |
| Disk | 60 GB |
| Swap | 2 GB persistent swap file |
| Login user | `derek`, using SSH public-key authentication |

DigitalOcean monitoring was enabled. DigitalOcean backups were intentionally
deferred until the site contains data that justifies the additional cost.

The cloud firewall should allow:

- TCP 22 for SSH, restricted to trusted source addresses where practical;
- TCP 80 for the HTTP-to-HTTPS redirect;
- TCP 443 for HTTPS;
- outbound traffic required for operating-system, Docker and application
  updates.

MariaDB port 3306 is not published on the host and must not be opened in the
cloud firewall.

## Architecture

The running stack uses Docker Compose:

| Service | Image or runtime | Purpose |
| --- | --- | --- |
| `web` | Custom `php:8.5.4-apache-bookworm` image | Chisimba and its PHP extensions |
| `db` | `mariadb:10.11.18` | The `chisimba` database |
| `nginx` | `nginx:1.31.3-alpine` | Public reverse proxy and TLS endpoint |

The PHP image recipe is derived from the audited PHP 8.5 development image in
`dev-environment/docker/php85/Dockerfile`. It installs GD, MySQLi, Mbstring,
XML and ZIP support and carries the repository's PHP configuration and runtime
error handling. The curated PEAR compatibility pack is part of the framework
source assembled into the release.

The initial IP deployment uses a self-signed certificate valid for the server
IP. Nginx also requires temporary HTTP authentication so that an anonymous
visitor cannot take control of the public Chisimba installer. This temporary
protection should remain until the installation is complete and the real
domain certificate is active.

## Server filesystem

Application releases and persistent data are separated:

```text
/srv/kengalearn/
├── app/
│   ├── current -> /srv/kengalearn/releases/release-TIMESTAMP/ch
│   └── deploy/
├── backups/
├── releases/
│   └── release-TIMESTAMP/
└── shared/
    ├── config/
    ├── error_log/
    ├── error_logs/
    ├── secrets/
    │   └── production.env
    ├── user_images/
    └── usrfiles/
```

The MariaDB data directory is held in the Docker volume named for the
`kengalearn-production` Compose project. It is not stored inside an application
release.

`shared/secrets/production.env` is mode `600` and contains the generated
database and temporary web-access secrets. Never commit this file, copy its
contents into documentation, or attach it to a public issue.

## Source of a release

The repository source is authoritative; the disposable runtime is not copied
to production. The deployment script assembles a new runtime from:

```text
/run/media/derek/main/chisimba-revival/framework/app
/run/media/derek/main/chisimba-revival/modules
/run/media/derek/main/chisimba-revival/canvases
/run/media/derek/main/chisimba-revival/dev-environment
```

It records the branch, commit and number of working-tree changes for each
repository. The release includes uncommitted working-tree changes, in keeping
with the current Chisimba development rule. The generated release archive is
checksummed before transfer and verified again on the server.

## Scripts

### `bootstrap-kengalearn-ubuntu2604-t4p7-20260813.sh`

This is the one-time host bootstrap. Run it on the server as `derek`; it uses
`sudo` only for host-level provisioning.

It:

- updates Ubuntu and installs basic deployment tools;
- creates and persists a 2 GB swap file;
- installs Docker Engine and Docker Compose from Docker's official repository;
- gives `derek` Docker access;
- bounds Docker log retention;
- creates `/srv/kengalearn` and its release/data boundaries;
- enables unattended security updates;
- disables password authentication and routine root SSH login;
- verifies Docker with a disposable test container;
- writes a timestamped report to `/home/derek/Downloads/`.

Before using it on a new host, create `derek`, grant sudo membership and copy a
verified SSH public key from the initial root account. Keep the root session
open until both SSH and `sudo -v` have been tested successfully as `derek`.

Example:

```bash
ssh derek@SERVER_IP
chmod +x ~/bootstrap-kengalearn-ubuntu2604-t4p7-20260813.sh
~/bootstrap-kengalearn-ubuntu2604-t4p7-20260813.sh
```

Reboot if its report says `REBOOT_REQUIRED=YES`, then reconnect as `derek`.

### `deploy-kengalearn-root-by-ip-r8q4-20260813.sh`

This performs the initial application deployment. Run it as `derek` on the
development desktop, not in an SSH session on the server.

It:

- verifies the four local source repositories and the prepared server;
- assembles a clean runtime from the current working trees;
- removes installer-completion markers from the new release;
- creates a self-contained PHP 8.5.4 build context;
- rewrites and verifies PHP's PEAR include path for the production web root;
- generates the production Compose and Nginx configuration;
- creates random database and temporary-access secrets on the server;
- protects writable application directories without making the source tree
  writable by Apache;
- creates temporary self-signed IP TLS and HTTP authentication;
- transfers a checksum-verified, timestamped release;
- starts and health-checks MariaDB, PHP/Apache and Nginx;
- writes a timestamped report to `/home/derek/Downloads/` on the desktop.

Example:

```bash
cd /home/derek/Downloads
chmod +x deploy-kengalearn-root-by-ip-r8q4-20260813.sh
./deploy-kengalearn-root-by-ip-r8q4-20260813.sh
```

The report contains temporary access and installer database credentials. It
must be treated as sensitive and must not be committed.

This script is for a fresh initial deployment. It is not yet the routine update
script: it does not implement the required pre-update backup and automatic
rollback contract.

### `resume-kengalearn-ip-auth-p3n7-20260813.sh`

This is a retained one-off recovery script from the first deployment. The
initial version created Nginx's hashed password file as mode `600`; Nginx's
unprivileged worker therefore returned HTTP 500 even though all containers were
healthy.

The recovery script changes only that hashed password file to mode `644`,
restarts Nginx, verifies authenticated HTTPS and prints the already-generated
installer settings. The main deployment script in this directory already
contains the correction, so this recovery script should not normally be needed
again. It remains here as evidence and as a narrowly bounded repair for a host
left in that exact partial state.

Example:

```bash
cd /home/derek/Downloads
chmod +x resume-kengalearn-ip-auth-p3n7-20260813.sh
./resume-kengalearn-ip-auth-p3n7-20260813.sh
```

## Completing the installer by IP

Browse to:

```text
https://104.248.35.30/
```

The browser will warn about the temporary self-signed certificate. After
accepting the warning, use the temporary access username and password from the
private deployment report.

Use the installer values reported by the deployment script:

```text
Database host:     db
Database name:     chisimba
Database username: chisimba
Database password: value reported as INSTALLER_DATABASE_PASSWORD
Site URL:          https://104.248.35.30/
```

Use a strong Chisimba administrator password. Password `a` is for disposable
test accounts only and must not be used for the production administrator.

## Routine container operations

Run these commands on the server as `derek`:

```bash
cd /srv/kengalearn/app/deploy

docker compose \
    --env-file /srv/kengalearn/shared/secrets/production.env \
    -f compose.yml \
    ps
```

Recent logs:

```bash
docker compose \
    --env-file /srv/kengalearn/shared/secrets/production.env \
    -f /srv/kengalearn/app/deploy/compose.yml \
    logs --tail=100 web nginx db
```

Restart only the application container:

```bash
docker compose \
    --env-file /srv/kengalearn/shared/secrets/production.env \
    -f /srv/kengalearn/app/deploy/compose.yml \
    restart web
```

The containers use `restart: unless-stopped`, so they return automatically
after a host reboot.

## DNS and trusted TLS

DNS was unavailable during the initial deployment because Namecheap's public
interface was under repair. When it becomes available:

1. Point the apex `kengalearn.com` A record to `104.248.35.30`.
2. Point `www.kengalearn.com` to the apex with a CNAME, or add a matching A
   record.
3. Add the IPv6 AAAA record only after IPv6 web access and firewall behaviour
   have been verified.
4. Replace Nginx's catch-all IP configuration with explicit
   `kengalearn.com` and `www.kengalearn.com` names.
5. Obtain and automatically renew a publicly trusted certificate.
6. Redirect `www` to the chosen canonical hostname.
7. Update Chisimba's canonical site URL from the temporary IP to
   `https://kengalearn.com/` through its established configuration path.
8. Remove the temporary installer HTTP authentication only after Chisimba is
   installed, the administrator login works and the public certificate is
   active.

Because Chisimba is already installed at `/`, changing from the IP address to
the domain does not require moving the application or rewriting a `/ch/` path.

## Production updates: required next implementation

Do not SSH into the live release and run `git pull`. The server intentionally
has no live Git working tree. A routine production update must be a new,
versioned release.

The update script still to be implemented must:

1. record the exact local commits and working-tree changes;
2. verify module `register.conf` versions were increased where required;
3. run local compatibility and smoke checks;
4. create a timestamped MariaDB dump;
5. create a timestamped archive of `shared/usrfiles` and other persistent
   uploaded assets;
6. assemble and checksum a new release from the current working tree;
7. transfer it into a new `/srv/kengalearn/releases/` directory;
8. retain the old `current` target for rollback;
9. switch `current`, restart the web service and run production smoke checks;
10. automatically restore the previous code release if verification fails;
11. report any database migration separately because code rollback does not
    automatically reverse a schema migration;
12. apply an explicit retention policy to old releases and backups.

This gives the project direct-to-production deployment without adding a staging
server, while retaining evidence, recoverability and a bounded rollback path.

Once the workflow stabilises, GitHub Actions can perform the tests and deploy
committed revisions. It cannot deploy uncommitted desktop changes, so the
desktop-driven release script remains appropriate while active development
depends on the current working tree.

## Reports and sensitive material

Each script writes one timestamped report under `/home/derek/Downloads/` on the
machine where it runs. Reports are deliberately named `killme-...` so they are
recognisable as temporary evidence.

Deployment and repair reports contain credentials. Do not add reports,
`production.env`, database dumps, uploaded files, certificates or private keys
to the `shellscripts` repository.
