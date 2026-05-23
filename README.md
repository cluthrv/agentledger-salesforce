# AgentLedger for Salesforce

Tamper-evident cryptographic audit trails for Salesforce Agentforce agents.

AgentLedger records every decision an autonomous AI agent makes using SHA-256 hash chains and Merkle trees. If any audit record is modified after sealing, integrity verification fails and the change becomes cryptographically detectable. The integrity violation becomes cryptographically detectable.

## The Problem

Agentforce agents are making autonomous decisions that change your business data: advancing opportunity stages, approving discounts, escalating cases, creating tasks, modifying records. Salesforce logs that these actions happened. What standard platform audit capabilities do not provide is cryptographic verification that an audit trail has remained unchanged after creation.

Standard platform audit logs are designed primarily for operational visibility and compliance monitoring, not for cryptographic immutability verification. For low-risk AI interactions, that level of assurance is sufficient. For autonomous decisions that affect revenue, pricing, compliance, or customer relationships, it creates a governance gap.

AgentLedger closes that gap.

## How It Works

AgentLedger provides three Invocable Actions that you add to any Agentforce subagent:

**Start Audited Session** creates a new audit session and links it to a Salesforce record (an Opportunity, Case, Account, or any object). Call this at the beginning of the agent workflow.

**Record Agent Action** captures a single agent decision with its action type, input data, output data, and reasoning. A SHA-256 hash is computed from the record's content. That hash includes the previous record's hash, forming a chain. Call this after each action the agent takes.

**Seal Audited Session** computes a Merkle tree from all recorded actions and stores the root hash on the session record. This single 64-character hash represents the entire session. After sealing, verification confirms that every hash matches its content and the chain is intact.

The auditing is embedded in the actions themselves.

## What Gets Recorded

For each agent action, AgentLedger stores:

- **Action Type**: Query, Decision, Calculation, Update, Create, Validation, Escalation, or Tool_Call
- **Input Context**: What data the agent looked at (structured JSON)
- **Output Result**: What the agent produced or decided (structured JSON)
- **Reasoning**: Why the agent took this action (natural language)
- **Record Hash**: SHA-256 hash of the record's content
- **Previous Hash**: Hash of the prior record, forming the chain
- **Timestamp**: When the action occurred
- **Sequence Number**: Position in the chain

No business data leaves Salesforce. Everything is stored in two custom objects within your org.

## Verification

Click the **Verify** button on any record page to run three integrity checks:

1. **Hash Chain Integrity**: Recomputes every record's hash from its current content. If any field was modified after creation, the computed hash won't match the stored hash.
2. **Merkle Root Integrity**: Recomputes the Merkle root from all record hashes. If any record was added, removed, or modified, the root won't match.
3. **Record Count**: Confirms the number of records matches the session's recorded count.

If all three pass, the audit trail is intact. If any check fails, the specific tampered record is identified.

## Use Cases

### Opportunity Qualification Agent

An Agentforce agent evaluates opportunities by querying account data, calculating win probability based on deal size and customer history, advancing the stage when criteria are met, and creating follow-up tasks. AgentLedger records every evaluation factor, the probability calculation, and the stage advancement decision.

When the sales VP asks "Why did the AI advance this deal?", the audit trail shows exactly what data the agent considered, what probability it calculated, and what criteria triggered the stage change. And the cryptographic chain proves nobody altered that reasoning after the fact.

### Case Escalation Agent

An agent monitors incoming cases, checks SLA thresholds, evaluates account tier and case severity, and escalates when criteria are met. AgentLedger records the SLA calculation, the escalation decision, the priority change, and the queue reassignment.

When a customer disputes the escalation path or an SLA breach occurs, the tamper-evident audit trail proves what the agent evaluated and when, and proves the records weren't modified after the incident.

### CPQ Pricing Agent

An agent retrieves dealer pricing rules, applies tier-specific discounts, validates floor prices, checks credit limits, and generates quotes. AgentLedger records every pricing calculation, discount application, and validation check.

When a pricing dispute arises or an audit reveals an unusual discount, the audit trail shows exactly what rules the agent applied, what thresholds it checked, and what calculations produced the final price. The hash chain proves the pricing rationale wasn't changed retroactively.

### Contract Review Agent

An agent analyzes contract documents, extracts key terms (renewal dates, liability caps, termination clauses), flags non-standard language, and routes for appropriate review. AgentLedger records what was extracted, what was flagged, and why it was routed to a specific reviewer.

When a contract dispute surfaces months later, the audit trail shows what the agent identified at review time, proving the AI's analysis wasn't altered after contract execution.

### Compliance Screening Agent

An agent performs KYC/AML checks on new accounts, evaluates risk scores, flags suspicious patterns, and determines required verification levels. AgentLedger records every screening factor, risk calculation, and verification decision.

When regulators audit the screening process, the tamper-evident trail proves what data the agent evaluated, what risk score it calculated, and that the screening records are intact since the original assessment.

### Order Approval Agent

An agent reviews purchase orders against inventory, validates shipping constraints, checks payment terms, and routes for approval based on order value and customer tier. AgentLedger records each validation step, the approval routing decision, and any exceptions granted.

When a fulfillment issue or billing dispute requires investigation, the audit trail provides a complete, verifiable record of every check the agent performed before approving the order.

## Integration Patterns

### No-Code (any admin can set up)

Add the three AgentLedger actions to any Agentforce subagent. Instruct the agent:

> "After each action you take, call 'Record Agent Action' with the session ID, the action type, a summary of what you looked at, a summary of what you decided, and your reasoning. After all actions are complete, call 'Seal Audited Session.'"

No Apex required. Works with any agent workflow.

### Apex Wrapper (for developers who want deeper control)

Write your own Invocable Actions that call `AgentAuditRecorder.recordAction()` internally. This gives full control over the JSON structure of inputs and outputs:

```apex
// Inside your custom Invocable Action
AgentAuditRecorder.recordAction(
    sessionId,
    'my-custom-agent',
    'Decision',
    JSON.serialize(inputData),
    JSON.serialize(outputData),
    'Escalated case because SLA breach is within 2 hours and account is Enterprise tier.'
);
```

The agent receives the same response it would from an unaudited action. The auditing is transparent.

### Flow Integration

AgentLedger's Invocable Actions are callable from Salesforce Flows. Use them in Screen Flows, Record-Triggered Flows, or Autolaunched Flows to add cryptographic auditing to any automated process, not just Agentforce agents.

## Record Page Component

The **AgentLedger Audit Trail** Lightning Web Component sits on any record page and displays all audit sessions linked to that record. Add it via Lightning App Builder:

1. Navigate to any record (Opportunity, Case, Account)
2. Click the gear icon, then Edit Page
3. Drag "AgentLedger Audit Trail" from Custom components onto the page
4. Save and activate

The component shows the agent name, session identifier, Merkle root, verification status, and every recorded action with its type, reasoning, hash, and chain link. Click **Verify** to re-run integrity verification on demand.

## Optional: Blockchain Anchoring

For maximum assurance, AgentLedger can anchor the Merkle root to an external blockchain (Ethereum or Arbitrum) after sealing a session. Only the 64-character root hash is stored on-chain. No business data, no customer information, no agent reasoning touches the blockchain.

External anchoring allows independent verification that a sealed audit session existed at a specific point in time and that its Merkle root has not changed.

Blockchain anchoring is optional and not required for the core tamper-detection functionality.

## Package Contents

| Component | Count | Description |
|---|---|---|
| Custom Objects | 2 | Agent_Audit_Session__c, Agent_Audit_Record__c |
| Core Apex Services | 3 | HashChainService, MerkleTreeService, AgentAuditRecorder |
| Invocable Actions | 3 | Start Session, Record Action, Seal Session |
| Lightning Web Components | 1 | Record page audit trail viewer with Verify button |
| Permission Set | 1 | AgentLedger_Admin |
| Test Classes | Full coverage | Core engine, actions, UI controller |

## Installation

Available on AppExchange (coming soon). Free.

## Related

- [AgentLedger Core Library](https://github.com/cluthrv/agentledger) (TypeScript, npm: @vluthra/agent-ledger)
- [Technical Documentation](docs/GUIDE.md)

## License

MIT

## Author

**Vikas Luthra** - Architect and Open Source Contributor
- LinkedIn: [linkedin.com/in/vikas-luthra-crm](https://linkedin.com/in/vikas-luthra-crm)
- GitHub: [github.com/cluthrv](https://github.com/cluthrv)