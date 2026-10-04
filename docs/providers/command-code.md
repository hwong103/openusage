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
| Today / Yesterday / Last 30 Days | Credits spent and tokens used in each window |
| Usage Trend | Per-day tokens used across the last 30 UTC days, as a sparkline |

Rows only appear when the account response contains usable data. OpenUsage also shows the plan reported
by Command Code, including Go, Pro, GOAT, Max, Ultra, and Teams Pro.

The spend rows feed the dashboard's Total Spend ring alongside Claude, Codex, Cursor, and Grok, so
Command Code shows up as a slice of Cost, Cost/MTok, and Tokens.

### About the day boundaries

Command Code's usage API accepts only a start instant, and it rounds that instant down to a UTC calendar
day. Its Today / Yesterday / Last 30 Days rows and its Usage Trend chart are therefore all UTC days,
while the log-scanned providers key their rows and their trend chart to your Mac's local calendar day.
Outside UTC the two sets of boundaries don't line up exactly, which is a limitation of the API rather
than a rounding choice.

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
- `/alpha/usage/summary?since=<ISO-8601-UTC-day-start>` supplies the Today, Yesterday, and Last 30 Days
  spend windows (the latter from thirty UTC days back; Yesterday is the second minus the first, since
  every window is cumulative from its own floor).

The Usage Trend is assembled on the client because the API has no per-day endpoint. Once per UTC day
OpenUsage requests the 31 UTC-day floors (in batches of four) and derives each day as the difference
between adjacent cumulative floors, then caches the result at
`~/Library/Application Support/OpenUsage/commandcode-spend-history.json`. Later refreshes only fold in
the already-fetched Today and Yesterday windows, so they make no extra requests. A day with no spend
stays a zero bar; an account with no usage in the window shows no trend row at all.

The key is sent only to Command Code as a Bearer credential.

## Troubleshooting

- **Not logged in**: run `cmd login`, or set `COMMAND_CODE_API_KEY`.
- **Session expired**: run `cmd login` again, or replace the exported key.
- **Invalid response**: the API returned a shape OpenUsage could not recognize; try again later.
- **Could not reach Command Code**: check the network connection and refresh again.
