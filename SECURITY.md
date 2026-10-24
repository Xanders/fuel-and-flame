# Security

Report vulnerabilities privately through the maintainer's GitHub security advisory channel. Never include secrets or real player data in a public issue.

Native applications must implement CredentialVault with OS-backed secure storage. Browser apps use Fuel's HttpOnly cookies. No default unencrypted persistent vault is provided. DemoVault is process-local test code only.

Keep the same command ID, epoch, revision and payload across retries. A timeout can follow a successful server mutation. A session lost on server restart cannot be restored from the SDK journal. Do not replace an account after an HTTP error.

Only connect to trusted HTTPS/WSS servers. Do not put credentials in URLs, logs, analytics, crash reports or screenshots. The application owns secure platform adapters and browser Origin/server configuration.
