# Security Policy

Security support for all versions of Better Auth Ruby ended on November 25, 2026.

## Report a vulnerability

To report a vulnerability privately, email `security@openparcel.dev`. Include
the affected version, steps to reproduce the issue, and its potential impact.

## Security Considerations

Better Auth Ruby handles sensitive authentication data. When contributing:

- Never log passwords, tokens, or session secrets
- Use the default `scrypt` password hasher. `bcrypt` is an optional supported
  alternative and requires the `bcrypt` gem.
- Use constant-time comparison for token validation
- Follow the same security patterns as the upstream TypeScript implementation
