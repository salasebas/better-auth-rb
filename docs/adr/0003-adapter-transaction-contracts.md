# ADR 0003: Ruby adapter transaction contracts

## Context

Better Auth v1.6.35 runs Memory transactions on a copy of the database and
merges row changes at commit. Its SQL adapter makes database transactions opt
in. RubyAuth already relies on SQL rollback for auth writes and migrations.

## Decision

RubyAuth's SQL adapters use database transactions. The public Memory adapter
runs transactions on a snapshot and merges their row changes at commit.
Organization mutations hold the Memory database lock through the transaction to
preserve capacity and ownership checks across concurrent requests.

Upstream resolves the active transaction adapter inside its internal adapter,
hooks, and organization adapter. RubyAuth also resolves it from
`ctx.context.adapter` so existing plugin code participates in the transaction.
A caller with a reference to the original Memory adapter can still read and
write the live database during a public Memory transaction.
