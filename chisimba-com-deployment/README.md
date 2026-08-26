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

Run from the workspace root:

```bash
bash shellscripts/chisimba-com-deployment/stage-exact-git-v1.sh
```

After the staged service is healthy, configure Apache for
`www.chisimba.com`, redirect `chisimba.com` to the canonical `www` host, issue
a certificate containing both names, and verify the public site before
retiring the old `dev.chisimba.com` virtual host.

The tracked Apache configuration redirects HTTP and the apex hostname to
canonical `https://www.chisimba.com/`. The TLS virtual host is the only public
proxy to the localhost-only application service.
