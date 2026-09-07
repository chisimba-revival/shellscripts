# Chisimba.com deployment

This deployment stages the public Chisimba information site as an isolated
PHP 8.5 application behind the existing Apache multi-site host.

The staging script:

- requires clean `main` branches that exactly match GitHub;
- builds a complete application release from Git archives;
- keeps configuration, uploads, logs and the MariaDB volume outside releases;
- exposes the application only on `127.0.0.1:8085`;
- does not change Apache, TLS or DNS;
- records the exact framework, modules and canvases commits in every release.
- recreates the web container after changing the release link, ensuring its
  bind mount resolves to the same release recorded by that identity file.

For routine updates, run this from the workspace root as Derek, without
`sudo`:

```bash
bash shellscripts/chisimba-com-deployment/deploy-chisimba-com.sh
```

The routine script checks that all three local repositories exactly match
GitHub, creates a database and persistent-file backup, tests the new release
before switching, automatically restores the preceding release if health or
public checks fail, and retains the current release plus one rollback release.
Only the newest verified database and persistent-file backup set is retained;
failed or older deployment backups are removed.
PHP sessions live in shared storage, so recreating the web container does not
sign an administrator out before module updates can be applied.

`stage-exact-git-v1.sh` is retained as the original provisioning script and
should not be used for routine updates.

After the staged service is healthy, configure Apache for
`www.chisimba.com`, redirect `chisimba.com` to the canonical `www` host, issue
a certificate containing both names, and verify the public site before
retiring the old `dev.chisimba.com` virtual host.

The tracked Apache configuration redirects HTTP and the apex hostname to
canonical `https://www.chisimba.com/`. The TLS virtual host is the only public
proxy to the localhost-only application service.
