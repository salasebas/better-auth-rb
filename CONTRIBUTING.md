# Contributing to Better Auth Ruby

Thank you for your interest in contributing to Better Auth Ruby. This guide will help you get started.

## Code of Conduct

This project is governed by our [Code of Conduct](CODE_OF_CONDUCT.md). By participating, you are expected to uphold this code.

## Project Structure

This is a monorepo with two Ruby gems:

```
packages/
  better_auth/            # Core auth library (Rack-based, framework-agnostic)
  better_auth-rails/      # Rails adapter (middleware, helpers, generators)
upstream/                 # Git submodule: original TypeScript better-auth (read-only reference)
```

## Getting Started

1. Fork the repository to your GitHub account

2. Clone your fork (with the submodule):

   ```bash
   git clone --recursive https://github.com/your-username/better-auth-rb.git
   cd better-auth-rb
   ```

3. Install Ruby 3.2+ (3.3 recommended). We recommend [rbenv](https://github.com/rbenv/rbenv) or [asdf](https://asdf-vm.com/).

4. Install dependencies:

   ```bash
   make install
   ```

5. Run the full CI to verify everything works:

   ```bash
   make ci
   ```

## Development Workflow

1. Create a new branch from `canary`:

   ```bash
   git checkout canary
   git pull origin canary
   git checkout -b type/description
   ```

   Branch prefixes: `feat/`, `fix/`, `docs/`, `refactor/`, `test/`, `chore/`

2. Make your changes following the code style guidelines

3. Run the linter:

   ```bash
   make lint-fix
   ```

4. Add tests for your changes (see Testing section below)

5. Run the test suite:

   ```bash
   make ci                # Full CI (lint + all tests)
   make test-core         # Only better_auth (Minitest)
   make test-rails        # Only better_auth-rails (RSpec)
   ```

6. Commit with a descriptive message:

   ```
   feat(core): add OAuth2 provider support
   fix(rails): resolve middleware ordering issue
   docs: improve installation guide
   ```

7. Push and open a PR against `canary`

## Code Style

We use [StandardRB](https://github.com/standardrb/standard) for formatting and linting:

```bash
make lint          # Check
make lint-fix      # Auto-fix
```

### Ruby Conventions

- 2 spaces for indentation
- `snake_case` for methods, variables, file names
- `CamelCase` for classes and modules
- `SCREAMING_SNAKE_CASE` for constants
- `# frozen_string_literal: true` pragma in all Ruby files
- Prefer single quotes unless interpolation is needed

## Testing

**All contributions must include tests.** We strongly prefer real integration tests over mocked unit tests.

### Core Library (`packages/better_auth/`)

Uses **Minitest**. Test files go in `test/` with `_test.rb` suffix:

```ruby
class SessionTest < Minitest::Test
  def test_creates_valid_session
    session = BetterAuth::Session.create(user_id: 1)
    assert session.valid?
  end
end
```

### Rails Adapter (`packages/better_auth-rails/`)

Uses **RSpec**. Test files go in `spec/` with `_spec.rb` suffix:

```ruby
RSpec.describe BetterAuth::Rails::Middleware do
  it "authenticates requests" do
    # ...
  end
end
```

### Testing Guidelines

- **Avoid mocks** unless the real dependency is truly impractical
- Test actual behavior, not implementation details
- If you need database containers: `make db-up`
- Check upstream tests (`upstream/packages/better-auth/src/**/*.test.ts`) for test case ideas

## Porting from Upstream

If you're porting a feature from the TypeScript upstream:

1. Read the upstream implementation in `upstream/packages/better-auth/src/`
2. Translate to idiomatic Ruby (not a line-by-line copy)
3. Port relevant test cases from `upstream/packages/better-auth/src/**/*.test.ts`
4. Reference the upstream PR/commit in your PR description

## Pull Request Process

1. PRs target `canary` (never `main` directly)
2. Keep PRs focused -- one feature or fix per PR
3. Write a clear description: what changed and why (2-3 lines)
4. Reference related issues (`Closes #123`)
5. Ensure CI passes (lint + tests)
6. Be responsive to review feedback

## Commit Conventions

We use [Conventional Commits](https://www.conventionalcommits.org/):

| Prefix | Use |
|--------|-----|
| `feat(core):` | New feature in better_auth |
| `feat(rails):` | New feature in better_auth-rails |
| `fix(core):` | Bug fix in better_auth |
| `fix(rails):` | Bug fix in better_auth-rails |
| `docs:` | Documentation changes |
| `chore:` | Tooling, CI, dependencies |
| `test:` | Test-only changes |

## Security Issues

For security vulnerabilities, **do not open a public issue**. Email [security@openparcel.dev](mailto:security@openparcel.dev) with details. See [SECURITY.md](SECURITY.md) for the full policy.
