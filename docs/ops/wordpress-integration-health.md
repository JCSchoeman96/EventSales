# WordPress integration health (WP-SOURCE-02)

Read-only observability for EventSales producer plugins on WordPress. No REST health route, no remote probes, no catalogue or order authority.

## Where to look

- **Site Health → Status:** direct tests for catalog feed, catalogue-change sender, order index feed, and order line identity.
- **Tools → Site Health → Info:** section **EventSales integrations** (boolean and version fields only).

## Health states

| State | Meaning |
|-------|---------|
| ABSENT | Plugin not installed |
| INACTIVE | Installed but not active |
| DISABLED | Optional sender intentionally off (not a failure) |
| MISCONFIGURED | Active but required local configuration missing |
| DEPENDENCY_UNAVAILABLE | Active but runtime dependency or storage missing |
| READY | Readiness requirements satisfied |

## Secret policy

Health output reports `authentication_configured`, `endpoint_configured`, and similar fields as **true/false** only. Secrets, tokens, endpoints with path tokens, and manifest contents are never included.

## Plugin path

```text
integrations/wordpress/eventsales-integration-health/
```

Symlink or copy into the local WordPress `wp-content/plugins/` tree for localhost verification.

## Tests

```bash
php -l integrations/wordpress/eventsales-integration-health/*.php
php integrations/wordpress/eventsales-integration-health/tests/integration-health-test.php
```
