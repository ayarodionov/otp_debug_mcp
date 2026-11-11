# ChatGPT recommendations for otp_debug_mcp

Review date: November 11, 2026.

This is a focused source review of the README, diagnostic runner, connection handling, conclusions, and blind evaluation script. Tests were not run. The recommendations below are proposed improvements, not claims of reproduced failures.

The priority is diagnostic accuracy and predictable production cost. The project already covers substantial ground; its strongest feature is turning BEAM operational knowledge into useful findings for an agent.

## 1. Make conclusions more cautious than the underlying measurements

Some generated conclusions assert more than the observation establishes. In `conclusions.ex`:

- Keeping whole binaries produces “nothing bounds how many.” A sample cannot establish whether the application has a bound.
- Growing native memory with flat VM memory becomes “a leak.” That is evidence to investigate; caches and other allocation behavior could also explain growth.
- Limit forecasts say the node “dies, in” a calculated duration, although that extrapolates the observed rate.

These sentences feed directly into the agent's reasoning. Return separate fields for observation, hypothesis, supporting evidence, limitations, and next check. Forecasts should say “at the observed rate, if sustained.”

[Source: conclusions.ex](https://github.com/ayarodionov/otp_debug_mcp/blob/main/lib/otp_debug_mcp/conclusions.ex)

## 2. Give diagnose an explicit cost budget

`Checks.run_all/0` runs two phases, with concurrency equal to the number of checks in each phase. The first phase includes 14 checks. Separating scans from load measurements is thoughtful, but several concurrent scans can still burden an already struggling node.

Proposed interface:

```text
diagnose(mode: "quick", budget_ms: 3000)
diagnose(mode: "deep", max_concurrency: 2)
```

The quick mode would avoid forced GC and expensive inspection. Results should report elapsed time, checks skipped, and incomplete coverage. Approval controls answer whether a check may run; budgets control how much work it may do.

[Source: checks.ex](https://github.com/ayarodionov/otp_debug_mcp/blob/main/lib/otp_debug_mcp/checks.ex)

## 3. Preserve raw measurements alongside footprint corrections

`Target.with_footprint/4` measures atom and code growth around debugger operations. Its own comment acknowledges that application growth during that window can be attributed to the debugger.

Subtracting the estimate can therefore conceal real growth. Expose fields such as:

```text
observed_atom_growth
estimated_debugger_contribution
adjusted_atom_growth
measurement_overlap
```

Keep the unadjusted result available and mark the correction as an estimate. This makes snapshot comparisons more trustworthy.

[Source: target.ex](https://github.com/ayarodionov/otp_debug_mcp/blob/main/lib/otp_debug_mcp/target.ex)

## 4. Strengthen blind evaluations beyond matching expected words

The existing live-node evaluation harness is a useful foundation. Its `check()` currently matches regular-expression groups against the final answer, and passing also requires a successful tool call.

An answer could mention the expected cause while making contradictory claims or proposing a harmful fix. Add:

- Healthy systems where the correct answer is “no fault established.”
- Similar symptoms with different causes.
- Assertions that conclusions cite actual returned evidence.
- Forbidden conclusions and inappropriate tool actions.
- Repeated runs to measure reliability.

Track false positives alongside successful diagnoses.

[Source: blind_eval.py](https://github.com/ayarodionov/otp_debug_mcp/blob/main/scripts/blind_eval.py)

## 5. Align connection timeouts with the whole connection operation

`Target.connect/2` uses the default `GenServer.call` timeout, while its handler performs distribution setup, connection, and recon injection. `attach/2` explicitly allows 30 seconds.

Give connection setup a deliberate overall deadline and stage-specific errors. Test slow recon injection and stalled connection establishment, including whether a timed-out caller leaves a connection operation continuing in the background. This is a potential failure path to verify, rather than a reproduced bug.

[Source: target.ex](https://github.com/ayarodionov/otp_debug_mcp/blob/main/lib/otp_debug_mcp/target.ex)

## Suggested first release

Address items 1, 2, and 4 first: more precise conclusions, a bounded quick diagnosis, and evaluations that penalize confident wrong answers. Those strengthen the project's central promise: helping an AI investigate a live system and reach a conclusion the operator can trust.
