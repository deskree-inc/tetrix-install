# AGENTS.md — tetrix-install

Instructions for AI coding agents (Cursor, Codex, Claude and others). This repository is **public**:
everything in it, and all of its GitHub activity, is readable by anyone.

## Never name a customer

Never write the name of a customer, tenant or prospect, or anything that identifies one. That covers:

- files, comments, docs, the `.env.example` comments and test fixtures
- file names, branch names, commit messages, PR titles and descriptions, review comments
- issues, release notes, and anything printed into CI logs (Actions logs here are public too)

Identifying details count too: their domain, cluster or tenant names, hostnames, and incident details
specific to them. Say "a customer install", "a large customer" or "a Cloud tenant" instead, even when
the task text names the customer. Release branches are `release/X.Y.Z`, never named after a customer.

Before every commit or PR, search the diff and the message for any customer name you know.

## Never put a secret in a workflow input or log

Licence tokens, passwords and API keys go in Actions secrets, never `workflow_dispatch` inputs. A
step's `env:` block is printed before `::add-mask::` runs, so a masked input still leaks into a public
log.
