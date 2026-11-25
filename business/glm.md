# GLM Coding Plan monitoring

Connect GLM in Settings → Accounts and enter the Z.ai Coding Plan API key. Each
connection stores its key under its own ID in the macOS Keychain. Z.ai supplies
the plan level. The account email is the label chosen when connecting the key.
A key change clears that connection's displayed limit until the next check.
**Remove API key** clears the stored key for that connection.

Fleet reads `https://api.z.ai/api/monitor/usage/quota/limit` using the same
authorization header as the Z.ai usage plugin. The app sends the key only to
that host and rejects redirects. Checks share the existing quota poller's
five-minute interval per key and respect Retry-After.
[Z.ai usage plugin](https://github.com/zai-org/zai-coding-plugins/blob/main/plugins/glm-plan-usage/skills/usage-query-skill/scripts/query-usage.mjs)

The response reports used percentages. Model windows use `TOKENS_LIMIT` or
`CREDIT_LIMIT`. Unit 3 with number 5 means five hours. Unit 6 with number 1
means seven days. Fleet shows `100 − used` and the reset timestamp if provided.
An absent or invalid percentage produces no measurement. The tool allowance
is outside these model quotas.

GLM is a monitored provider. Use a compatible coding client to run the models.

`GLMCodingPlanTests` protects window mapping, exhausted limits and account
attribution. Test fixtures exercise the quota contract without a subscriber key.
