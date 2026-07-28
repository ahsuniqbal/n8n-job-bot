# Documentation Index

This folder contains the full design and runtime documentation for the n8n Job Bot project.

| # | File | What's inside |
|---|------|----------------|
| 01 | [Overview](01-overview.md) | What the project is, why it exists, what it does and does not do |
| 02 | [Problem & Solution](02-problem-solution.md) | The problem space and the design principles that shape the solution |
| 03 | [Workflow](03-workflow.md) | Stage-by-stage description of the pipeline from trigger to email |
| 04 | [Tools & Nodes](04-tools-nodes.md) | Infrastructure stack, external services, node inventory, schema |
| 05 | [Diagram](05-diagram.md) | Mermaid diagrams: end-to-end flow, source fan-out, container topology |
| 06 | [Workflow Deep Dive](06-workflow-deep-dive.md) | Every n8n node explained — config, expressions, reasoning |

## Where to start

- **New to the project?** Read 01 → 02 → 05 (diagrams) for the mental model.
- **Setting up the stack?** Read 04 for the tools, then the root [README](../README.md) for the install steps.
- **Modifying a node?** Jump straight to 06 and search for the node name.
- **Debugging a run?** 03 maps stages to symptoms; 06 has the exact configuration per node.
