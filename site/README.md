# Snapper launch page

Invite-only page for Snapper. Someone enters an email; if it is on the invite list they get an email with a
download link that serves the newest `.dmg` from the GitHub release. Anyone else gets the same neutral reply and
you get an email so you can invite them.

## Deploy on Vercel

1. Add New, Project, import this repository.
2. Set **Root Directory** to `site`. No build command, no framework.
3. Add the environment variables below, then deploy.

## Environment variables

| Name | What it is |
| --- | --- |
| `INVITE_EMAILS` | Comma-separated invite list. Exact addresses, or a whole domain as `@company.com`. |
| `RESEND_API_KEY` | API key from resend.com. |
| `MAIL_FROM` | Sender on a domain you verified in Resend, e.g. `Snapper <hello@yourdomain.com>`. |
| `SIGNING_SECRET` | Long random string (32+ characters). Signs the emailed links. |
| `OWNER_EMAIL` | Where requests from people not on the list are sent. Optional. |
| `SITE_URL` | Public URL of this site, e.g. `https://snapper.yourdomain.com`. Optional. |
| `GITHUB_TOKEN` | Optional. Raises the GitHub API rate limit. A token with no scopes is enough. |
| `SNAPPER_REPO` | Optional. Defaults to `arif12islam/snapper`. |
| `REPORTS_EMAIL` | Optional. Where crash and error reports from the app are emailed. Defaults to `OWNER_EMAIL`. |

Generate a secret with `openssl rand -base64 32`.

## Adding someone

Add their address to `INVITE_EMAILS` in Vercel, then redeploy (Deployments, Redeploy). Environment variable
changes apply to new deployments only.

## What the gate does and does not do

The links in the emails expire after 7 days and cannot be forged, but the `.dmg` itself lives in a public GitHub
release, so anyone who finds that URL can download it. This keeps casual visitors out and tells you who asked.
For a hard gate the repository and its releases would have to be private, and the in-app updater, which reads the
public release feed, would stop working.

## Crash and error reports

`/api/report` receives the anonymous reports people opt into in Snapper (Settings, General, Privacy). Every report
is written to the function log (Vercel, the project, Logs, search `snapper-report`) and emailed to `REPORTS_EMAIL`
(or `OWNER_EMAIL`) when one is set. The app sends to `https://snapper-arif12islams-projects.vercel.app/api/report`
by default; build with `SNAPPER_REPORT_URL=https://… ./build.sh` to point it elsewhere.
