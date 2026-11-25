# Parity check

Two prompts for comparing RubyAuth with an upstream Better Auth version. The
first checks one feature. The second runs the first across features in
parallel, one fresh-context agent per feature. Copy a prompt, fill in the
`<...>` values, and give it to an agent.

Each check quotes both sides of every difference, so the run needs no separate
validation pass.

## Check one feature

```text
Check RubyAuth parity for one feature.

Feature: <an entry or group from docs/supported-features.md>
Target version: <TO, for example 1.6.35>
Previous version: <FROM, for example 1.6.23, or "none" for a full check>
Parent issue: <number of "Parity with Better Auth v<TO>">
Earlier parity issues: <numbers, for example #165, or "none">

1. Fetch the versions: ./scripts/fetch-upstream-better-auth.sh <TO>, and
   ./scripts/fetch-upstream-better-auth.sh <FROM> unless FROM is "none".
2. Find the upstream code to compare, using the feature's upstream paths in
   docs/supported-features.md:
   - With a previous version, take only what changed: git diff --no-index
     reference/upstream-src/<FROM>/repository/packages/<path>
     reference/upstream-src/<TO>/repository/packages/<path>, tests included.
   - Without one, take the feature's whole upstream source and tests at TO.
3. For each upstream behavior in that scope, read the matching Ruby code from
   the entry and compare what a caller observes: status, error code and
   message, response shape, cookies, stored data, side effects, validation
   order, and options or endpoints. Skip everything that
   docs/adr/0002-unsupported-upstream-features.md excludes.
4. Record a difference only with a quote of both sides: Ruby path:line and the
   upstream link https://github.com/better-auth/better-auth/blob/v<TO>/<path>#L<n>.
5. File each difference:
   - If a sub-issue of the parent issue or of an earlier parity issue already
     covers it, add a comment to that sub-issue.
   - Otherwise open an issue titled "<what to port> (v<TO>)" and add it as a
     sub-issue of the parent issue.
   - If upstream now behaves like Ruby, comment that the existing finding is
     resolved.

Do not edit repository files, commit, or start subagents.

Reply with these four sections, each one empty or a list with issue links:
- Blockers: what has to land before this feature can be ported.
- New differences: what you filed, and where.
- Risks we introduced: Ruby behavior that differs from upstream on purpose
  or by accident, and is not a documented adaptation. Leave out upstream's own
  risks.
- Upstream features still pending: new in TO, missing in Ruby, not excluded by
  ADR 0002.
```

## Run it across features

```text
Run RubyAuth parity checks from <FROM> to <TO>.

1. Fetch both versions with ./scripts/fetch-upstream-better-auth.sh.
2. Find the open issue "Parity with Better Auth v<TO>", or create it. Note its
   number and the numbers of earlier open parity issues, such as #165. Each
   parent holds at most 100 sub-issues.
3. For each entry in docs/supported-features.md, check whether its upstream
   paths changed: git diff --no-index --quiet on the two
   reference/upstream-src/<version>/repository/packages/<path> directories.
   For a full check (FROM "none"), take every entry.
4. For each selected entry, start a separate agent with fresh context, all in
   parallel: a subagent, a delegated task, or a thread, whichever your
   environment offers. Give it the "Check one feature" prompt from
   docs/agents/parity-check.md, filled in for that entry with both issue
   numbers.
5. When every agent finishes, reply with the four sections merged across
   features. Add each "Upstream features still pending" item to the Planned
   section of docs/supported-features.md in one PR.
```
