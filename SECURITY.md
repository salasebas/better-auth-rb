# Security Policy

## Reporting a Vulnerability

If you believe you've found a security vulnerability, please follow these steps:

1. **Do not** disclose the vulnerability publicly until it has been addressed by our team.
2. Email your findings to `security@openparcel.dev`. Include:
   - A description of the vulnerability
   - Steps to reproduce the vulnerability
   - Potential impact of the vulnerability
   - Any suggestions for mitigation
3. We will respond to your report within 72 hours.
4. If the issue is confirmed, we will release a patch as soon as possible.

## Disclosure Policy

If the issue is confirmed, we will release a patch as soon as possible. Once a patch is released, we will disclose the issue publicly. If 90 days have elapsed and we still don't have a fix, we will disclose the issue publicly.

## Supported Versions

We only support the latest version of each major/minor release line. Older patch versions within a supported line receive security fixes through a new patch release.

| Version | Supported |
|---------|-----------|
| 0.x (latest) | Yes |
| < 0.x | No |

## Security Considerations

Better Auth Ruby handles sensitive authentication data. When contributing:

- Never log passwords, tokens, or session secrets
- Use the default `scrypt` password hasher. `bcrypt` is an optional supported
  alternative and requires the `bcrypt` gem.
- Use constant-time comparison for token validation
- Follow the same security patterns as the upstream TypeScript implementation
