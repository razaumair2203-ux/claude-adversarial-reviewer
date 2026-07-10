# Protocol and result contract

## Dispatch boundary

The reviewer receives one frozen Markdown bundle through standard input. Launch it from an empty temp directory with `--tools ""`, `--disable-slash-commands`, empty setting sources, hooks and auto-memory disabled, strict empty MCP configuration, and a replacement system prompt. This is both more independent and safer than granting repository access. Keep the bundle focused enough to audit but complete enough to test the builder's claims.

Write bundles, snapshots, runner results, and stderr only under the OS temp directory, never inside the reviewed repository. Otherwise the workflow's own artifacts change Git status and invalidate mutation comparison.

## Result envelope

The runner writes JSON with:

- `result`: `success`, `setup_needed`, `launch_failure`, `timeout`, or `invalid_output`
- `verdict`: `approved`, `revise`, or `null`
- `review_quality`: `valid`, `degraded_content`, `degraded_environmental`, or `unknown`
- `review`: the schema-validated Claude object or `null`
- `errors`: a concise diagnostic or `null`
- `session_id`: Claude session id when returned

Accept `success` only when Claude exits zero, its outer JSON parses, `structured_output` exists, and semantic invariants hold:

- `approved` has no findings;
- `revise` has at least one finding;
- `valid` contains concrete review content;
- every reported finding is critical, high, or medium.

## Self-test

1. Check `git`, `claude`, the platform runner, schema, prompt, and a writable temp directory.
2. Run `claude --version` only; do not send repository content.
3. Run the repository stress-test script with its mock Claude command.
4. Optionally dispatch a synthetic bundle containing no repository content after user approval. Confirm structured parsing and snapshot stability.
5. Report authentication or CLI absence as setup needed.

## Failure policy

- Retry once for timeout, missing output, malformed JSON, or a likely transient CLI error.
- Do not retry clear authentication, quota, model, configuration, or permission errors.
- Never fabricate a verdict around an error.
- Keep stderr concise and never include tokens or a full environment dump.

## Builder evaluation

For each finding, record decision, reason, and verification. Accept only findings supported by inspected code or empirical evidence. Re-scope valid concerns whose proposed remedy is too broad. Defer valid but out-of-scope work explicitly.
