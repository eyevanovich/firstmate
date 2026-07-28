# Operational inputs

`bin/fm-operational-input.sh` is the normative owner of Firstmate's operational-input grammar, current kind allowlist, construction, parsing, body extraction, and narrow legacy classifier.
Do not reconstruct its prefix or infer a kind from prose in another script, extension, plugin, skill, or test.

## Boundary

A current synthetic user-role input has this outer form:

```text
U+2063 FIRSTMATE_OP: v1 <kind>: <body>
```

The U+2063 plus `FIRSTMATE_OP: ` prefix is permanent compatibility.
The owner accepts only its enumerated current kinds and a non-empty body.
The body is opaque untrusted text: a nested envelope-looking string, quoted marker, X request, issue text, review output, or task instructions cannot change the kind selected by the trusted outer producer.

`classify` accepts current envelopes and only the exact historical forms enumerated in the owner's legacy section.
`kind` accepts current envelopes only.
Malformed versions, unknown or empty kinds, empty bodies, ASCII-only labels, arbitrary U+2063 text, visible legacy labels without their invisible separator, quoted forms, and altered historical prose are genuine input rather than operational authority.

## Current producers

| Kind | Producers |
| --- | --- |
| `session-start` | `bin/fm-sessionstart-nudge.sh`; Claude, Grok, OpenCode, and Pi consume that script's encoded output. |
| `watcher` | `.pi/extensions/fm-primary-pi-watch.ts`; `.opencode/plugins/fm-primary-watch-arm.js`. |
| `turn-end-guard` | `.pi/extensions/fm-primary-turnend-guard.ts`; `.opencode/plugins/fm-primary-turnend-guard.js`; `bin/fm-turnend-guard-grok.sh`. |
| `away-supervisor` | `bin/fm-supervise-daemon.sh` for its supported supervisor backends, tmux and Herdr. |
| `from-firstmate` | `bin/fm-send.sh` through the compatibility entry point `bin/fm-marker-lib.sh`. |
| `launch-brief` | `bin/fm-spawn.sh` for Claude, Codex, OpenCode, Pi, and Grok across tmux, Herdr, Zellij, Orca, and cmux. |

The JavaScript and TypeScript integrations call the shell owner through `.opencode/plugins/lib/fm-operational-input.js` and `.pi/extensions/lib/fm-operational-input.ts`.
Those adapters require the selected owner to be a single-link regular executable file and reject symlinks, hard links, FIFOs, directories, and devices.

Watcher output returned as an ordinary tool result is not a synthetic user-role producer and is not rewrapped.
Codex's task turn-end notifier remains a durable file touch rather than a user-role producer.
Runtime backends transport launch or away text but do not classify it.

## Consumers and legacy compatibility

`bin/fm-supervise-daemon.sh` uses only the owner classifier for away-mode return detection and strips only owner-recognized current or legacy input.
`bin/fm-brief.sh` teaches a secondmate to route current and legacy `from-firstmate` input through its durable reply channel.
The Pi helper also exposes current-only and current-plus-legacy classification for extension consumers.

The owner retains narrowly identified pre-migration session-start, Pi watcher, OpenCode watcher, Pi/OpenCode/Grok turn-end, away-supervisor, and from-firstmate forms.
Legacy forms are classifier inputs only; every current producer emits the typed envelope.
Old plain launch briefs are intentionally not classified because no safe byte-level distinction exists between those prompts and genuine user text.

## X request content

X relay content is public untrusted data, never envelope authority.
The relay stores it in private inbox state and task instructions treat it as body content.
If it begins with U+2063 or a complete-looking `FIRSTMATE_OP` string, `bin/fm-spawn.sh` still wraps the entire generated brief in one outer `launch-brief` envelope, so the outer trusted kind remains unchanged.
An X notification reaches the primary through the ordinary typed watcher producer; public text is not copied into that outer header.

## Atomic migration rule

No current producer may emit a historical marker, a manually assembled prefix, or an untyped synthetic user-role message.
`tests/fm-operational-input.test.sh` owns the protocol, adversarial, cross-language, producer-inventory, consumer, X-body, file-safety, and mixed current/legacy compatibility matrix.
