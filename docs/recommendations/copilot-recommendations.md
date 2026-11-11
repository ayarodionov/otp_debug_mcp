# Copilot recommendations

At the referenced commit, the project already has broad diagnostics and substantial CI coverage. I’d prioritize these improvements:

1. **Avoid creating atoms from tool inputs.** [`Tools.resolve_process`](https://github.com/ayarodionov/otp_debug_mcp/blob/6de936c08ef89c8cd9ee7fc1c3652f392d983065/lib/otp_debug_mcp/tools.ex#L68) converts process names with `String.to_atom` and `Module.concat`; [`Target.connect`](https://github.com/ayarodionov/otp_debug_mcp/blob/6de936c08ef89c8cd9ee7fc1c3652f392d983065/lib/otp_debug_mcp/target.ex#L377) also converts a supplied node name. Atoms aren’t garbage-collected, so validate inputs and avoid creating new atoms from arbitrary strings; add regression tests for these paths.

2. **Close the two documented compatibility gaps.** The [TODO list](https://github.com/ayarodionov/otp_debug_mcp/blob/6de936c08ef89c8cd9ee7fc1c3652f392d983065/README.md#L756) calls out missing recon on older targets without `compiler`, and `trace_calls` potentially disturbing existing tracing on OTP 26 and earlier. These are especially worthwhile because they affect availability and operational safety.

3. **Broaden version-specific CI where practical.** The [full test matrix](https://github.com/ayarodionov/otp_debug_mcp/blob/6de936c08ef89c8cd9ee7fc1c3652f392d983065/.github/workflows/ci.yml#L8) runs on OTP 27–28, while OTP 26 and 29 get focused compatibility jobs. Expanding those jobs to exercise more of the suite would catch regressions in the advertised version range earlier.

4. **Make the first-use path easier to scan.** The README’s large tool catalog is useful as a reference, but a short task-oriented quick start—connect, diagnose, investigate a finding—could help new users get started before they need the full catalog.
