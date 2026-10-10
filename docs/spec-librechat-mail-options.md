# Spec: LibreChat options for e-mail verification and domain sign-up

[← Back to docs](README.md)

**Status:** proposed on 2026-10-10, **not implemented**. Extends [decision: how LibreChat is installed](decision-librechat-install.md) (point 5 and its open questions). It is **not part of `install --defaults`**: the defaults stay as specified there (open until the first account, then closed). This is for an administrator who has tried the product and generates the [VM post-install script](spec-vm-generator.md) for a real use.

## Goal

Let an administrator describe, in the [configuration file](spec-config.md) or on the command line, a LibreChat where **people of one e-mail domain sign up by themselves and must verify their address**. Nothing here is a new component: it is options of the existing `chat-interface librechat` script, validated through its `describe` like the others, so that `apply` and the generator accept them with no code specific to LibreChat.

The project does not provide a mail server in this step: LibreChat sends its mail through an **SMTP relay the administrator gives** (their own server, a provider). An optional `mail` component, planned in the [open questions](decision-librechat-install.md#open-questions), may later provide one.

## Why a domain list alone is refused

LibreChat's `registration.allowedDomains` checks the **text** of the address. Without a verification that the person owns the mailbox, anybody can type `anyone@corp.com`. So `registration-domains` is only accepted together with the verification, and the verification needs a working mail path. The script checks that path before changing anything.

## Options

All on `chat-interface librechat`, in `describe` (so the generator asks for them in its options step and `config validate` checks them). An empty value means "not set". LibreChat names in the last column are those of 0.8.7 **to confirm** on the VM before the implementation.

| Option | Env | Type, default | Meaning | LibreChat |
| --- | --- | --- | --- | --- |
| `public-url` | `EASY_CS_AI_LIBRECHAT_PUBLIC_URL` | string, empty | The URL people use, the one inside the verification link. Empty: derived as today (`https://<server-name>:<site-port>` from the proxy, else the loopback URL) | `DOMAIN_CLIENT`, `DOMAIN_SERVER` |
| `email-verification` | `…_EMAIL_VERIFICATION` | boolean, `false` | (Forced on by `--registration domain`.) An account must verify its address by the mail LibreChat sends before it can log in | `ALLOW_UNVERIFIED_EMAIL_LOGIN=false` |
| `registration-domains` | `…_REGISTRATION_DOMAINS` | string, empty | Comma-separated e-mail domains allowed to sign up (`corp.com,corp.fr`); required by, and only valid with, `--registration domain` | `registration.allowedDomains` of `librechat.yaml` |
| `smtp-host` | `…_SMTP_HOST` | string, empty | Host name or address of the SMTP relay | `EMAIL_HOST` |
| `smtp-port` | `…_SMTP_PORT` | integer 1–65535, `587` | Port of the relay | `EMAIL_PORT` |
| `smtp-security` | `…_SMTP_SECURITY` | enum `starttls`, `tls`, `none`; `starttls` | Encryption of the connection | `EMAIL_ENCRYPTION` |
| `smtp-allow-selfsigned` | `…_SMTP_ALLOW_SELFSIGNED` | boolean, `false` | Accept a certificate that is not trusted (an internal CA). Carries a `warn` | `EMAIL_ALLOW_SELFSIGNED` |
| `smtp-user` | `…_SMTP_USER` | string, empty | Login on the relay (empty: no authentication) | `EMAIL_USERNAME` |
| `smtp-password` | `…_SMTP_PASSWORD` | **secret**, no default | Password of the relay, see [Secret](#the-smtp-password) | `EMAIL_PASSWORD` |
| `smtp-from` | `…_SMTP_FROM` | string, empty | Sender address of the mails, which the relay must accept | `EMAIL_FROM` |
| `smtp-from-name` | `…_SMTP_FROM_NAME` | string, `LibreChat` | Sender name | `EMAIL_FROM_NAME` |
| `smtp-check` | `…_SMTP_CHECK` | boolean, `true` | Check the relay before changing anything (see [Check](#the-check-of-the-relay)) | none |

The sign-up itself is set by the `registration` option of the [decision](decision-librechat-install.md#the-registration-option) (`first-account` by default, `open`, `domain`, `closed`); the options below only matter for `domain`, and for the mail of the other modes. `registration-domains` is the list of `domain`.

### Validation (exit 2, before any side effect)

Same rules in `describe` (type, `values`, `min`, `max`) for what a program can check, and in the script for the rest. Each message names the option.

- `registration-domains`: every item matches a domain (letters, digits, hyphens and dots, at least one dot, lowercase after normalisation, no `@`, no wildcard, no spaces except around commas); duplicates are dropped. Set with a `registration` other than `domain`: error ("registration-domains only applies to --registration domain"). `registration domain` without it: error.
- `registration domain` forces the verification on; `email-verification false` with it is an error ("a domain list without verification checks only the text of the address"). `email-verification` `true` (needed by `domain`, allowed with the other modes) requires `smtp-host` and `smtp-from`, and a usable `public-url` (see next point).
- **The link must open from a browser.** With `email-verification` `true`, a `public-url` that is empty and a derived URL that is the loopback (no proxy `server-name`) is an error: the link in the mail would point to the VM itself. `public-url` must be `http://` or `https://`, a host and an optional port, **no path, no credentials, no trailing slash**. A host that differs from the `server-name` of the installed proxy gives a `WARN` (the certificate is issued for the `server-name`, the browser will warn or refuse).
- `smtp-security` `none` with a host that is not the loopback: error (the password and the mails would travel in clear). `smtp-allow-selfsigned` `true` gives a `WARN` (the relay is not authenticated).
- `smtp-user` set with no password source, or a password given with no user: error.
- `smtp-from` must be one address (`name@domain`), `smtp-from-name` a single line with no control character.
- No value may contain a newline or a NUL: they are written to `librechat.env`.

## The SMTP password

A secret option, with the [channels of the contract](spec-script-contract.md#secrets): `--smtp-password-file <path>` (mode `0600` or stricter), the variable `EASY_CS_AI_LIBRECHAT_SMTP_PASSWORD`, or `-` for stdin. In the configuration file, `{ "file": … }` or `{ "env": … }`, never a literal (see [spec: config](spec-config.md#secrets)); the file or the variable must therefore exist on the VM **before** the script runs, which the generator documents (the user-data of a cloud is not confidential).

**One difference with the other secrets: it is never generated.** The contract generates a secret when none is given; a made-up relay password is meaningless. `describe` marks the option `"generate": false`; `{ "generate": true }` for it is a `secret_source` error of `config validate`, and a missing source with a `smtp-user` is the usage error above.

It is stored in `/etc/easy-cs-ai/secrets/librechat.smtp-password` (mode `0600`, root), **kept by every later run** like the other secrets, and written into `librechat.env` as `EMAIL_PASSWORD`. A later run without the option keeps the stored one; giving it again replaces it, which recreates the `api` container. It never appears in a log, `--dry-run`, `describe`, `status`, the state or the journal. To test before the implementation: a password with spaces, `$`, `#`, quotes and `\` must reach LibreChat unchanged through the compose `env_file` (otherwise the file writer quotes or refuses the character, and says so).

## Rendering

- `librechat.env` gets two blocks, `${LC_EMAIL_BLOCK}` (the `EMAIL_*` lines, only the ones whose option is set, and `ALLOW_UNVERIFIED_EMAIL_LOGIN`) and the `DOMAIN_CLIENT` / `DOMAIN_SERVER` lines from `public-url` (else as today). Like `LC_ENDPOINTS_BLOCK` for `librechat.yaml`, the template stays a plain `envsubst` file.
- `librechat.yaml` gets `${LC_REGISTRATION_BLOCK}`: a `registration:` entry with `allowedDomains:` (the validated list, one per line) when `registration-domains` is set, nothing otherwise. `add-endpoint` and `remove-endpoint`, which rewrite this file, keep the block (the options are read from the recorded `params`, as `adopt_recorded_params` does for the others).
- A change of any of these options **recreates only the `api` container**, once, and only when a rendered file changed (the rule of the script). Which of them LibreChat reads at start only, and whether `librechat.yaml` needs the recreation too, is to be confirmed.

## Registration modes

One option, `registration`, defined in the [decision](decision-librechat-install.md#the-registration-option): `first-account` (default), `open`, `domain`, `closed`. This spec adds what `domain` needs and how the mail options combine with each mode:

| Mode | `registration-domains` | Verification | Notes |
| --- | --- | --- | --- |
| `first-account` | not allowed | optional (`email-verification`) | The first account, the administrator, is verified like any other if it is on |
| `open` | not allowed | optional | Open to anybody who owns a mailbox when verification is on; still carries the warning |
| `domain` | **required** | **always on** (needs the SMTP options and a usable `public-url`) | Open for good to those domains; no watcher |
| `closed` | not allowed | optional (the mail serves the accounts created later, if any) | Nobody signs up |

A mode and an option that do not go together are a usage error (exit 2) naming both. `config validate` and the generator show the **mode in words**, and the effective verification.

### The first administrator

LibreChat makes the **first account** its administrator. With verification and a domain on from the install:

- the first account must **match the domain** and **verify its address** like any other. If the relay is wrong, nobody can log in at all; this is why the relay is [checked at install](#the-check-of-the-relay) and `test-mail` exists;
- an administrator whose address is **outside the domain** cannot register; they create their account with the native command (`easy-cs-ai exec chat-interface librechat exec api npm run create-user`, which works with the registration closed). **Observed on 2026-10-10 (LibreChat 0.8.7, no mail service configured)**: a sign-up answers "Please check your email to verify your email address" yet the account is stored with `emailVerified: true`, and `create-user` also creates it verified (`--email-verified=false` printed `true`), so with **no mail service the verification flag means nothing**; what happens with a mail service configured is still to test, as is whether an account created **before** the verification was turned on can still log in afterwards. `create-user` takes `<email> <name> <username>` as arguments and asks for the password on stdin when it is not the 4th argument (which is not recommended); several prompts piped on one stdin did not work, one password on stdin did. The result decides what to document, and perhaps whether the script must mark the accounts present at the switch as verified.

## The check of the relay

When `smtp-host` is set and `smtp-check` is `true`, `install` checks the relay in its **preflight, before any change**, with `curl` (already a dependency of the package), without sending a mail: connection to `smtp-host:smtp-port`, the TLS negotiation of `smtp-security` (a certificate that is not trusted fails unless `smtp-allow-selfsigned`), and the authentication when a user is given. A failure stops the install with **exit 5** and a message that says which step failed; nothing was changed. `smtp-check` `false` is for a VM whose network to the relay is not up yet (the unit tests and a VM built offline); it gives a `WARN`.

A check that passes proves the relay accepts the connection and the login, **not that the mail reaches the mailbox** (the receiving side may still refuse the sender). So there is also an action to prove it end to end:

`easy-cs-ai chat-interface librechat test-mail <address>`: sends one test mail from `smtp-from` through the recorded relay (`curl`, the stored password, same security) and prints what the relay answered. Read-only for the installation (no recreation, nothing recorded); not journaled with the address. Added to the `actions` of `describe`. It does not need LibreChat running.

## State, status and logs

- `params` records the non-secret options: `public-url`, `email-verification`, `registration-domains`, `smtp-host`, `smtp-port`, `smtp-security`, `smtp-allow-selfsigned`, `smtp-user`, `smtp-from`, `smtp-from-name`, `smtp-check`. Never the password; the file is listed in `secrets`. The journal carries the same non-secret set.
- `status` shows `registration` (the mode asked and whether it is open or closed, see the [registration option](decision-librechat-install.md#the-registration-option)) and, when the verification is on, the relay as `host:port`, with no probe (a mail relay is not health-checked at each `status`).
- `uninstall` keeps the password file with the other secrets, `--purge` removes it.

## Generator and configuration file

No code specific to these options: the generator reads `describe`, so they appear in its options step (`smtp-password` as a secret, asked as a path or a variable name, never a value). A configuration:

```json
{ "type": "chat-interface", "name": "librechat", "options": {
    "registration": "domain",
    "public-url": "https://chat.corp.com",
    "registration-domains": "corp.com",
    "smtp-host": "smtp.corp.com", "smtp-port": 587, "smtp-security": "starttls",
    "smtp-user": "chat@corp.com", "smtp-password": { "file": "/root/smtp-password" },
    "smtp-from": "chat@corp.com" } }
```

The summary of the generator shows the **effective registration mode** in words, and the `warn` entries (`smtp-allow-selfsigned`).

## Tests

- `bats` (`EASY_CS_AI_ROOT` mode, fake `curl`): each validation error and its message, the effective default of the closing option, the rendering of both blocks with and without the options, the password channels (file mode, env, stdin), the password absent from every output, the check (connection, TLS, authentication, failure exit 5, `smtp-check false`), `test-mail`, idempotence (a re-run changes nothing, one changed option recreates only `api`), state and journal.
- VM (integration): a **Mailpit** container as the SMTP relay on the VM catches the verification mail; the run installs with the options, registers an account of the domain, reads the link in the mail, verifies, logs in, then tries an account of another domain (refused) and an unverified login (refused). The delivery to a real mailbox is **not testable** in this harness and is said so.

## Open points

- The LibreChat variable names and the effect of each on the container (see the tables above) and the `create-user` behaviour with the verification on: to confirm on LibreChat 0.8.7 first.
- Whether `public-url` should also configure the proxy (`server-name`, certificate name), instead of only warning on a difference.
- `ALLOW_PASSWORD_RESET` (reset by mail) uses the same relay and is **not enabled** here; a later option.
- OAuth/OpenID sign-in is another way to restrict a sign-up to an organisation, with no mail, and is not designed.
