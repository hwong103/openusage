# Command Code

Tracks [Command Code](https://commandcode.ai/) subscription windows, balance, and request activity.

## What it tracks

| Metric | Meaning |
|---|---|
| Session | Current rolling five-hour window |
| Weekly | Current rolling seven-day window |
| Monthly | Usage against the current billing-cycle credits |
| Requests | Requests made during the current billing cycle |
| Balance | Remaining plan, purchased, and free credits |

Rows only appear when the account response contains usable data. OpenUsage also shows the plan reported
by Command Code, including Go, Pro, GOAT, Max, Ultra, and Teams Pro.

## Where credentials come from

OpenUsage checks these sources in order:

1. `COMMAND_CODE_API_KEY`
2. `COMMANDCODE_API_KEY`
3. `apiKey` in `~/.commandcode/auth.json`
4. This fork's protected router key at `~/.codex/codex-router/commandcode-api-key.secret`

The first three are the normal Command Code paths. The final fallback lets this fork use an existing
Command Code login on machines where the CLI itself is not installed. OpenUsage reads only the key and
does not display or log it.

## Under the hood

OpenUsage makes read-only `GET` requests to `https://api.commandcode.ai`:

- `/alpha/whoami?limits=1` resolves the personal or organization account.
- `/alpha/billing/credits` returns balance and rolling window limits.
- `/alpha/billing/subscriptions` returns the plan and billing period.
- `/alpha/usage/summary?since=<ISO-8601-period-start>` returns request and monthly usage totals.

The key is sent only to Command Code as a Bearer credential.

## Troubleshooting

- **Not logged in**: run `cmd login`, or set `COMMAND_CODE_API_KEY`.
- **Session expired**: run `cmd login` again, or replace the exported key.
- **Invalid response**: the API returned a shape OpenUsage could not recognize; try again later.
- **Could not reach Command Code**: check the network connection and refresh again.
