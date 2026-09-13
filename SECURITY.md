# Security

Please report vulnerabilities privately through [GitHub's vulnerability reporting form](https://github.com/hosseintoussi/agentchirp/security/advisories/new).

Include the affected version, macOS version, reproduction steps, and the expected
impact. Remove API keys, signing credentials, transcripts, and personal project
paths from any attachments. Do not include a working credential as proof.

Please avoid public issues for undisclosed vulnerabilities. Ordinary bugs and
feature requests can use GitHub issues. Security fixes target the latest release;
older releases may need an upgrade.

AgentChirp's source, hook definitions, and Sparkle public verification key are
public. Signing private keys, Apple app-specific passwords, credential exports,
and real agent session data must never be committed. Release credentials belong
in the protected `release` GitHub environment or a local Keychain.
