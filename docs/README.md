# vfrhi documentation

The repository README is the short version. These guides cover the
ideas, contracts, and workflows that need more room.

| Document | Best for | What it explains |
| --- | --- | --- |
| [Overview](overview.md) | Evaluating the project | What vfrhi is, how the repository is organized, the design principles behind the interface, and what the project deliberately does not do |
| [Using the interface](usage.md) | Application developers | Backend and resource lifetimes, implicit dependencies between resources, command recording, synchronization, data transfer, queries, and GPU-free tests |
| [Backends](backends.md) | Application developers, backend authors | What each backend requires from the platform, how it behaves, where its guarantees differ, and how shaders reach the native API |
| [Building and testing](building.md) | Everyone | Root builds, dependency builds, build options, test commands, examples, and CI behavior |
| [Implementing a backend](implementing-a-backend.md) | Backend authors | The contract behind every `Device` and `Queue` vtable entry, how handles and errors are validated, and how to extend the resource and command model |
| [Contributing](contributing.md) | Contributors | Reporting bugs, preparing fixes, adding backends or API surface, the testing bar, and review expectations |

The API reference itself lives in the Zig source. Every public type,
function, and important field carries a doc comment, so the source is
the authoritative place to look up exact parameter and error lists.

If you are new to the project, read the overview first, then the usage
guide. If you plan to add a backend, read the backends page and the
backend implementation guide together.

The repository rules in [`AGENT.md`](../AGENT.md) are mandatory for
changes that touch the source tree. They cover naming, logging, build
wiring, resource checklists, and the prohibitions that keep backends
independent.
