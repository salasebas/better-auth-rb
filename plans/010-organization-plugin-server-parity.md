# Plan 010: Complete server parity tests for the organization plugin

> **Executor instructions**: Follow this plan step by step. Run every
> verification command and confirm the expected result before moving to the
> next step. If anything in the "STOP conditions" section occurs, stop and
> report; do not improvise. When done, update the status row for this plan in
> `plans/README.md`.
>
> **Drift check (run first)**: `git diff --stat 7920aee..HEAD -- packages/better_auth/lib/better_auth/plugins/organization.rb packages/better_auth/lib/better_auth/plugins/organization/schema.rb packages/better_auth/test/better_auth/plugins/organization_test.rb packages/better_auth/test/support/upstream_server_parity.rb`

## Status

- **Priority**: P1
- **Effort**: L
- **Risk**: HIGH
- **Depends on**: `plans/006-server-parity-inventory-and-test-harness.md`, `plans/009-core-route-parity-account-user-password-email-signin-signup.md`
- **Category**: tests
- **Planned at**: commit `7920aee`, 2026-06-15

## Why this matters

Organization is the largest server-side plugin gap. Upstream has broad coverage
for org CRUD, invitations, members, teams, permissions, dynamic access control,
hooks, limits, role updates, additional fields, and returned:false fields. Ruby
has a compact 19-test file that covers important happy paths and some security
edges, but not the full server behavior surface.

## Current state

Relevant upstream organization suites:

- `plugins/organization/organization.test.ts`: 92 tests.
- `plugins/organization/routes/crud-access-control.test.ts`: 23 tests.
- `plugins/organization/routes/crud-members.test.ts`: 18 tests.
- `plugins/organization/routes/crud-org.test.ts`: 18 tests.
- `plugins/organization/team.test.ts`: 25 tests.
- `plugins/organization/organization-hook.test.ts`: 4 tests.
- `plugins/organization/client.test.ts`: 2 client-only tests; exclude from Ruby
  server parity.

Current Ruby implementation anchors:

```text
packages/better_auth/lib/better_auth/plugins/organization.rb:77-135
organization(options) registers core endpoints, conditionally adds team
endpoints when teams.enabled, conditionally adds dynamic access control role
endpoints when dynamic_access_control.enabled, and attaches schema/error codes.

packages/better_auth/lib/better_auth/plugins/organization.rb:158-203
organization_create_endpoint validates user/name/slug, checks creation limits,
runs hooks, creates organization/member/default team, and sets active org cookie.

packages/better_auth/lib/better_auth/plugins/organization.rb:206-214
organization_check_slug_endpoint uses request_only_session, so direct API calls
can check without a Rack session but HTTP requests require session.
```

Current Ruby tests in `organization_test.rb` cover:

- create/list/update/activate/delete organization.
- check slug request-only behavior.
- invite/accept/list/update/remove member.
- active organization and internal user ID.
- clearing active organization.
- get full organization member limits.
- invitation limits, duplicates, wrong recipient, expiry, re-invite/cancel.
- invitation hooks.
- teams, dynamic access control, additional fields, returned:false fields, and
  owner role update in compressed form.

## Commands you will need

| Purpose | Command | Expected on success |
| --- | --- | --- |
| Organization tests | `cd packages/better_auth && bundle exec ruby -Itest test/better_auth/plugins/organization_test.rb` | exit 0 |
| Inventory | `cd packages/better_auth && bundle exec ruby -Itest test/better_auth/upstream_server_parity_inventory_test.rb` | exit 0 |
| Core tests | `cd packages/better_auth && bundle exec rake test` | exit 0 |
| Lint | `cd packages/better_auth && bundle exec standardrb` | exit 0 |

## Scope

**In scope**:

- `packages/better_auth/test/better_auth/plugins/organization_test.rb`
- `packages/better_auth/test/support/upstream_server_parity.rb`
- Small source fixes in `organization.rb` or `organization/schema.rb` only when
  a new parity test exposes a confirmed mismatch.

**Out of scope**:

- `plugins/organization/client.test.ts` client API shape.
- Type-only assertions in upstream `organization.test.ts`.
- External packages and framework adapters.
- Rewriting organization implementation structure.

## Git workflow

- Branch: `test/organization-plugin-parity`
- Commit message style: `test(core): expand organization plugin parity coverage`
- Do not push or open a PR unless the operator instructed it.

## Steps

### Step 1: Split the current organization test file if needed

`organization_test.rb` is already about 600 lines. If adding all coverage makes
it hard to review, split by server domain under the same directory:

- `plugins/organization_test.rb` can keep the smoke/full-flow tests.
- New optional files:
  - `plugins/organization_members_test.rb`
  - `plugins/organization_teams_test.rb`
  - `plugins/organization_access_control_test.rb`
  - `plugins/organization_hooks_test.rb`

If you split, keep shared helpers local or use Plan 006 helpers. Do not move
unrelated tests unless it improves readability for this plugin only.

**Verify**: `cd packages/better_auth && bundle exec ruby -Itest test/better_auth/plugins/organization_test.rb` -> exit 0 before adding new files.

### Step 2: Port org CRUD and get-full-organization coverage

Read upstream `organization.test.ts` and `routes/crud-org.test.ts`. Add tests for:

- Create organization with logo, metadata, additional fields, and default team.
- `allow_user_to_create_organization` boolean false and callable false.
- `organization_limit` numeric and callable.
- Duplicate slug error distinctions: create duplicate versus check-slug taken.
- Update by `organizationId` and by slug; reject empty name/slug and slug owned
  by another org.
- Delete organization removes related members, invitations, teams, and active
  session org/team state.
- `get_full_organization` fallback to active organization, explicit missing org,
  member limit, team inclusion, invitation inclusion, and permission failures.
- Returned fields respect schema `returned: false`.

**Verify**: `cd packages/better_auth && bundle exec ruby -Itest test/better_auth/plugins/organization_test.rb` plus any new org CRUD file -> exit 0.

### Step 3: Port invitation and member coverage

Read upstream `organization.test.ts` invitation sections and
`routes/crud-members.test.ts`. Add tests for:

- Invite role arrays, invalid roles, inviting existing member, inviting existing
  pending invite, invitation limit, invitation expiry, canceled/rejected states.
- `cancel_pending_invitations_on_re_invite` and resend/reuse existing behavior.
- Accept/reject requires recipient email and, when configured, verified email.
- Inviter removed/no longer member paths.
- List invitations and user invitations filter by pending status as upstream.
- List members pagination/search/sort if implemented; otherwise mark exact
  Ruby not-applicable options in the inventory.
- Add member rejects duplicate member and respects membership limit.
- Remove member rejects last owner removal and ownerless org.
- Leave organization handles only-owner and ownerless safeguards.
- Update member role accepts string/array roles and validates permissions.
- Active member and active member role endpoints.

**Verify**: `cd packages/better_auth && bundle exec ruby -Itest test/better_auth/plugins/organization_test.rb` plus any new member file -> exit 0.

### Step 4: Port team coverage

Read upstream `team.test.ts`. Add tests for:

- Teams disabled does not register team endpoints.
- Create team, list organization teams, list user teams, update team, remove
  team.
- Default team creation on organization creation and option to disable it.
- Maximum team count and team member limit.
- Add/remove/list team members and permission failures.
- Active team set/clear, active team returned in session, active organization
  hook refresh behavior.
- Multi-team support if Ruby implementation exposes it.

If a team feature is not implemented in Ruby, do not silently skip it. Mark the
inventory as `:partial` with the exact missing endpoint/option.

**Verify**: `cd packages/better_auth && bundle exec ruby -Itest test/better_auth/plugins/organization_test.rb` plus any new team file -> exit 0.

### Step 5: Port dynamic access control and role coverage

Read upstream `routes/crud-access-control.test.ts` and access-control sections
inside `organization.test.ts`. Add tests for:

- Dynamic access control disabled does not register role CRUD endpoints.
- Create/list/get/update/delete org roles.
- Invalid resource/action permissions rejected.
- Duplicate role names rejected.
- Cannot delete predefined roles.
- Cannot delete assigned role.
- DB permissions merge with built-in roles.
- Owner can update roles only when authorized.
- Permission checks for organization/member/invitation/team resources.

**Verify**: `cd packages/better_auth && bundle exec ruby -Itest test/better_auth/plugins/organization_test.rb` plus any new access-control file -> exit 0.

### Step 6: Port hooks and additional fields coverage

Read upstream `organization-hook.test.ts` and additional-fields sections. Add
tests for:

- `before_create_organization`, `after_create_organization`,
  `before_update_organization`, `after_update_organization`,
  `before_delete_organization`, invitation hooks, and member hooks run with
  expected data and can override data where Ruby supports it.
- Database hooks can create organization-related rows if Ruby supports that
  hook path.
- Additional fields for organization, member, invitation, team, and role
  validate required/input:false/default/returned:false.
- Returned:false fields are stored but absent from API output.

**Verify**: `cd packages/better_auth && bundle exec ruby -Itest test/better_auth/plugins/organization_test.rb` plus any new hooks file -> exit 0.

### Step 7: Update the parity inventory

Update entries for:

- `plugins/organization/organization.test.ts`
- `plugins/organization/routes/crud-access-control.test.ts`
- `plugins/organization/routes/crud-members.test.ts`
- `plugins/organization/routes/crud-org.test.ts`
- `plugins/organization/team.test.ts`
- `plugins/organization/organization-hook.test.ts`
- `plugins/organization/client.test.ts` as excluded client-only.

Use `:covered` only for server-applicable suites that are fully represented.
Leave `:partial` with exact missing endpoints/options where Ruby does not yet
implement upstream behavior.

**Verify**: `cd packages/better_auth && bundle exec ruby -Itest test/better_auth/upstream_server_parity_inventory_test.rb` -> exit 0.

### Step 8: Run core verification

**Verify**:

- `cd packages/better_auth && bundle exec ruby -Itest test/better_auth/plugins/organization_test.rb` plus any new organization-specific test files -> exit 0.
- `cd packages/better_auth && bundle exec rake test` -> exit 0.
- `cd packages/better_auth && bundle exec standardrb` -> exit 0.

## Test plan

Use real `BetterAuth.auth` with memory adapter and actual API calls. Avoid mocks
except for hooks/callback lambdas whose only purpose is observing calls. Keep
setup helpers explicit: owner cookie, member cookie, organization, team, and
invitation IDs should be created through public plugin endpoints.

## Done criteria

- [ ] Organization server upstream suites are fully represented or have exact
  `:partial` inventory notes.
- [ ] Tests cover org CRUD, invitations, members, teams, access control, hooks,
  and additional fields.
- [ ] The client-only organization upstream test is explicitly excluded.
- [ ] Targeted organization tests, full core tests, and StandardRB all exit 0.

## STOP conditions

Stop and report back if:

- A missing upstream behavior requires designing a new public Ruby API rather
  than adding tests for existing behavior.
- A source fix risks changing authorization semantics outside organization.
- The organization test file becomes too large to review and splitting it would
  require moving unrelated tests.
- A verification command fails twice after a reasonable fix attempt.

## Maintenance notes

This is the highest-blast-radius plugin test plan. Reviewers should check
permission expectations and last-owner safeguards carefully. Do not accept
tests that assert only that a response is truthy; these routes need concrete
status, data, and side-effect assertions.
