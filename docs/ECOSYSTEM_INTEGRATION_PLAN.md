# Integration Plan: Nadeem Bitar Ecosystem & Hermes Agent

This document outlines the architectural mapping and integration roadmap for incorporating the Nadeem Bitar Haskell ecosystem into the Hermes Agent framework to enable autonomous campaign execution.

## 1. Core Architectural Mapping

| Haskell Component | Hermes Role | Technical Definition |
| :--- | :--- | :--- |
| **Shikumi** | Decision/Planning | Logic Plugin: Evaluates states, generates repair blueprints, and decides next actions. |
| **Keiro** | Durable Orchestration | Workflow Runner: Ensures persistence, resumability, and state-machine integrity. |
| **Kioku** | Memory Backend | Episodic/Semantic Memory: Provides the context store for lessons, history, and known-fails. |

## 2. Infrastructure & Auxiliary Components

| Haskell Component | Hermes Role | Technical Definition |
| :--- | :--- | :--- |
| **Seihou** | Agent Scaffolding | Dhall-Typed Config Tool: Injects strictly-typed orchestration policies. |
| **Shomei** | Security/Identity | Security Tool: Handles passkey/signing operations within the campaign. |
| **Kiroku** | Event Sourcing Store | Memory/Logging Tool: Append-only store for auditing decisions and events. |
| **Mori-Schema** | Protocol Enforcement | Validation Tool: Enforces input/output JSON schemas for agent tool calls. |
| **PGMQ-HS** | Communication Backbone | Message Queue: Facilitates reliable inter-agent messaging. |
|| **Shibuya-PGMQ Adapter** | Transport Bridge | Adapter: Links Shibuya pipelines to PGMQ queues. |
|| **Shibuya** | Data Pipeline Processor | Effectful Pipeline Tool: Manages async streams and transformation flows. |

## 3. Autonomous Integration Flow

To enable the agent to autonomously proceed through a plan, the loop is:

1.  **Observability (Trigger):** Hermes detects an event (e.g., test failure).
2.  **Context Retrieval (Kioku):** Agent queries the **Kioku Memory Plugin** for historical precedents or known failure baselines.
3.  **Decision (Shikumi/Seihou):** Agent invokes the **Shikumi Decision Tool** (scaffolded by **Seihou**) with diagnostics to obtain a "Repair Blueprint."
4.  **Action (Keiro/PGMQ/Shibuya-PGMQ):** Agent calls the **Keiro Durable Workflow Plugin**. The **Shibuya-PGMQ Adapter** enqueues a blueprint via **PGMQ**. A separate worker event loop (running **Shikumi-Eval**) processes the blueprint and journals the result back via **Kiroku**.
5.  **Persistence (Kiroku/Kioku):** **Kiroku** journals the event; upon completion, **Kioku** updates the final result for future reference.
6.  **Verification (Mori):** All structured exchanges are validated via **Mori-Schema** middleware.

## 4. Implementation Roadmap (Tiered)

- **Tier 1 (Foundations):** 
  - Integrate **Seihou** (scaffolding).
  - Implement **Orchestrator-Worker Transport Bridge** (using **Shibuya-PGMQ Adapter**).
  - Implement **Asynchronous Worker Event Loop** (consuming **PGMQ**, evaluating via **Shikumi-Eval**).
- **Tier 2 (Governance/Security):** Integrate **Shomei** (security/identity) and **Mori-Schema** (validation).
- **Tier 3 (Audit/Provenance):** Integrate **Kiroku** (event sourcing/auditing).
