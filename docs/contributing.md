# Contributing

vfrhi is pre-1.0 and still small enough that a focused contribution can
change the shape of the project. Contributions are welcome in several
forms: bug reports, fixes to existing backends, new backend
implementations, additional resources or commands, translator coverage,
tests, examples, and documentation.

The most useful contribution is usually the smallest one that makes a
real call sequence work correctly on every affected backend. A narrow,
well-tested change is easier to review than a broad refactor, even when
the broad refactor is tempting.

## Reporting a bug

Open an issue at
[github.com/Verafahn/vfrhi/issues](https://github.com/Verafahn/vfrhi/issues)
with enough information to reproduce the problem. A good report names
the affected **backend**, the operating system and GPU driver, and the
Zig version. If the problem is visual, include the example that shows it
and a screenshot. If it is a crash or an error return, include the call
sequence that leads to it and the relevant log output at debug or warn
level.

Say whether the **test backend** reproduces the problem. If it does, a
minimal call sequence is often enough to turn the report into a
regression test. If it does not, the issue is likely in a native
backend, a translator, or a platform integration, and the report should
say which backend was running.

## Fixing a bug

Reproduce the problem before changing code. If the test backend can
model the failing sequence, add a test in `src/tests.zig` that fails for
the right reason, then fix the cause. If the problem only exists on a
GPU backend, reproduce it with the relevant example first and keep the
change as close to the failing path as possible.

Do not paper over a validation failure by weakening the test backend.
The test backend exists to state the intended contract clearly; a native
backend that disagrees with it is usually the thing that needs fixing.
Conversely, if the interface itself is ambiguous, improve the contract
and the documentation together instead of encoding the ambiguity in one
backend.

After a fix, run the headless suite:

```sh
zig build test --summary all
```

Then run the example that exercises the changed path on real hardware.
The triangle example is the minimum for any rendering backend change.
Texture or descriptor changes also need the texture example, element
buffer changes need the quad example, and batch drawing changes need the
batch example.

## Adding a backend

A new backend is a substantial contribution. It must implement the same
`Device` and `Queue` interfaces as the existing backends, not just the
subset needed by one example. That means every resource tag, every
command, mapping, the command buffer state machine, queue submission,
presentation, and capability queries.

Start with the [backend implementation guide](implementing-a-backend.md).
It describes the build wiring, the handle invariants, and the contract
behind each virtual table entry. Use the test backend as the reference
for validation order and state transitions, and use the Vulkan backend
as the reference for a direct mapping of the abstract model.

The new backend must respect the project's dependency rules. A backend
may use only the packages its build option enables, and it must not make
those packages mandatory for users who disable it. It must not create
windows, contexts, event loops, or message pumps. If the native API does
not consume SPIR-V, the translation belongs inside the backend and must
return `error.Unsupported` rather than silently compiling different
semantics.

Every backend needs a compile test in `src/tests.zig`, documentation in
`docs/backends.md`, and a build option entry in `docs/building.md`. Run
at least the triangle example on hardware before submitting the change,
and say in the pull request which operating system, driver, and backend
were exercised.

## Extending resources and commands

The interface is designed to grow through tagged unions, not through new
virtual functions. A new resource extends `Resource.Tag` and
`Resource.Description`, adds description and property types, adds a
typed wrapper in `src/resources/`, and is implemented by the test
backend and every GPU backend. A new command extends the `Command`
union, gets a `CommandBuffer` method and a `WithAddr` variant, and is
validated by the test backend and recorded by every GPU backend.

The full checklist is in [`AGENT.md`](../AGENT.md) and repeated with
more context in the [backend implementation
guide](implementing-a-backend.md). Two rules are easy to underestimate.
First, a new resource must be implementable on Windows with both
Direct3D backends as well as on Vulkan and OpenGL, not only on the
backend you happen to be testing. Second, a new API addition needs a
failure-path test as well as a success-path test, and dependency-order
violations should be asserted explicitly when the resource introduces a
new edge.

Do not add a virtual function for a single resource or a single
operation. If a feature does not fit the existing categories, explain
why in the issue before extending the interface.

## Tests and validation

The automated suite runs without a GPU and covers the interface, the
test backend, resource lifetimes, command validation, and both shader
translators. It is the first gate for every change.

```sh
zig build test --summary all
zig build test -Ddisable-render --summary all
```

The second command is the smallest configuration and is useful when a
change should not depend on any graphics API. CI runs the render-disabled
build on Linux, Windows, and macOS in Debug, ReleaseFast, and ReleaseSafe.

Tests should use `Test.init`, exercise the real resource and command
code, destroy every resource, and call `Test.validate` before `deinit`.
Use `warn` for errors that a test intentionally provokes; the Zig test
runner treats `err` output as a failure, so the test backend reports
expected validation failures at warning level. A test that expects a
destruction-order violation should first assert that the violation is
rejected, then destroy the remaining resources in the correct order and
validate.

GPU behavior is not covered by CI. When a change touches a backend,
run the relevant example with a finite frame count so the run exits on
its own:

```sh
cd examples/triangle
zig build run -- --backend vulkan --frames 2
```

Use `opengl`, `dx3d11`, or `dx3d12` for the other backends. A change to
a SPIR-V translator also needs a GPU-free translator test in
`src/tests.zig`, because the automated suite cannot compile the
generated shader on a driver.

## Code style and documentation

Follow the naming and layering rules in [`AGENT.md`](../AGENT.md):
`snake_case` for variables, fields, and constants, `PascalCase` for
types, `camelCase` for functions, and `snake_case` for virtual table
fields. Keep the raw wrapper, convenience wrapper, `WithAddr` wrapper,
and typed wrapper layers distinct. Do not add a shortcut that bypasses
the virtual table.

Public declarations need English doc comments following the
`zig-api-docs` template used throughout the source. The overview comes
first, followed by the applicable `# Args`, `# Return`, `# Error`,
`# Note`, `# Compile Error`, and `# Panic` sections in that order. Do
not copy a re-exported declaration's doc comment onto the re-export;
document the original.

The user documentation in `docs/` is written as continuous prose.
Prefer a paragraph that explains a relationship over a list of
fragments, and use a table only when the items really are parallel and
the table is easier to scan than prose. Bold the key term in a sentence
rather than the whole sentence. Documentation is English only, and it
should explain the contract rather than restating parameter lists that
already live in the source doc comments.

When behavior changes, update the affected guide. A backend behavior
change belongs in `docs/backends.md`; a lifetime or synchronization
change belongs in `docs/usage.md`; a build option change belongs in
`docs/building.md`. If the change affects the front page, keep the
README short and link to the detailed page instead of growing it.

## Submitting changes

Keep a pull request focused on one problem. Avoid unrelated formatting,
renames, or refactors in the same change; they make review slower and
hide the actual behavior change. If a cleanup is necessary to make the
fix possible, explain that in the description.

Write commit subjects in the imperative mood and keep the body for
information that is not already in the subject, such as the reason for
the change or a non-obvious tradeoff. A pull request description should
state the problem, the approach, the tests that were run, and the
hardware or backend used for manual validation.

All changes must pass the repository CI. Because the project is
pre-1.0, an API change may be accepted if it makes the backend contract
clearer, but it needs a justification and updates to every affected
backend, test, example, and document. Reviewers may ask for additional
failure-path tests, a smaller scope, or a design discussion before the
change lands.

If you are unsure where to start, the test backend and the translator
tests are the easiest places to learn the codebase. Both run without a
GPU, and both make the expected behavior explicit.
