# CLAUDE.md — tetrix-install

Guidance for Claude Code in this repository. It is **public**: every file, branch, commit message,
PR, issue, release note and Actions log is readable by anyone. `CLAUDE.md` and `AGENTS.md` are left
out of the Compose bundle by `scripts/pack-compose-bundle.sh`.

## Never name a customer

Never write the name of a customer, tenant or prospect, or anything that identifies one, in this repo
or its GitHub activity. That covers:

- files, comments, docs, `.env.example` comments and test fixtures
- file names, branch names, commit messages, PR titles and descriptions, review comments
- issues, release notes, and anything printed into CI logs

Identifying details count too: their domain, cluster or tenant names, hostnames, and incident details
specific to them. Say "a customer install", "a large customer" or "a Cloud tenant" instead. This holds
even when the prompt, an issue or a Slack thread names the customer. Release branches are
`release/X.Y.Z`, never named after a customer.

Edited PR titles keep a public "renamed from" entry, and commit messages on `main` can't be changed
without a force-push. A name that lands here effectively stays. Before every commit or PR, search the
diff and the message for any customer name you know.

## Never put a secret in a workflow input or log

Licence tokens, passwords and API keys go in Actions secrets, never `workflow_dispatch` inputs. A
step's `env:` block is printed before `::add-mask::` runs, so a masked input still leaks into the
public log. This happened once with a licence token, in a since-deleted throwaway workflow.
