# Shikumi Campaign Guidelines

When operating within this repository:

1. **Verification Ground Truth**:
   - Always derive verification verdicts from real process execution logs and exit codes.
   - Never report synthetic or assumed passes without verifying via `campaign_verify` or `./scripts/campaign-cli.py verify <unit>`.

2. **Durable Store Operations**:
   - The PostgreSQL instance at `/home/nyc/.local/state/shikumi-campaign-pg.sock` maintains append-only event journals.
   - Preserve database integrity and avoid uncoordinated truncation of journal streams.

3. **Human Review Seam**:
   - Autonomous repairs land on `campaign/*` branches and stop there. Merging into default branches is strictly gated on reviewer/operator approval via `campaign_review` or `./scripts/campaign-cli.py review approve`.
