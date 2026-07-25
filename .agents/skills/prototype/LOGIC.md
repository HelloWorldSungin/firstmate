<!-- Adapted from Matt Pocock's prototype skill. MIT License. Copyright (c) 2026 Matt Pocock. -->

# Logic Prototype

Build a tiny interactive terminal app for manually exercising business logic, state transitions, or data shape.
State the exact question in a README or top-of-file comment before writing code.

Use the host project's language and tooling.
Put the decision-bearing logic behind a small pure interface such as a reducer, explicit state machine, pure function set, or narrow stateful module.
Keep terminal I/O out of that interface.

Render one stable terminal frame containing the full state and available actions.
Read one input at a time, apply it, and re-render until quit.
The entire view should fit on one screen.

Provide one run command through the existing task runner.
Record what cases changed the design judgment and the final verdict in the scout report.

Do not add tests, use a production database, generalize beyond the question, mix terminal I/O into the logic, or ship the terminal shell.
