# Slack webhook secrets

Git ignores everything in this folder except this README. Alertmanager reads two files from here:

| File | Slack channel | Gets |
|------|---------------|------|
| `slack-page-url` | `#alerts-page` | `severity=page` alerts |
| `slack-ticket-url` | `#alerts-ticket` | `severity=ticket` alerts |

Setup:

1. Create a Slack workspace (free) with the channels `#alerts-page` and `#alerts-ticket`.
2. At <https://api.slack.com/apps>, create an app **from scratch**, open **Incoming Webhooks**, turn them on, and
   click **Add New Webhook to Workspace** once for each channel.
3. Save each URL as the only content of its file:
   ```bash
   printf '%s' 'https://hooks.slack.com/services/...' > alertmanager/secrets/slack-page-url
   printf '%s' 'https://hooks.slack.com/services/...' > alertmanager/secrets/slack-ticket-url
   ```
4. `docker compose restart alertmanager`

Until the files exist, Alertmanager logs a failed Slack send for each notification, and the local
`alert-logger` still receives everything.

A webhook URL is a credential: anyone who has it can post to your channel. If one leaks, delete it in the
Slack app settings and create a new one.
