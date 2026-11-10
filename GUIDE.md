# AgentLedger for Agentforce: Guide

How to connect an agent, what AgentLedger stores, and how it works.

## Connect an agent

### 1. Use the agent's API name as its Agent Id

Every AgentLedger action takes an **Agent Id**. Use the agent's API name (for
example `CaseEscalationAgent`, shown on the Setup page). AgentLedger then finds
the agent's definition and records its version and instructions on every run.
If you use another value, set **Agentforce Agent** for it on the Setup page.

### 2. Give the agent the AgentLedger actions

In Agentforce Builder, open the agent's subagent → **Actions** → **New → Add
from Asset Library**:

| Add | Instead of | Why |
| --- | --- | --- |
| **Get Record (AgentLedger)** | Get Record Details | Logs what the agent looked at. |
| **Update Record (AgentLedger)** | Update Record | The change and its log entry are one transaction, with before and after values. |
| **Create Record (AgentLedger)** | Create Record | Logs the new record and its values. |
| **Record Agent Action** | | Logs decisions, recommendations and reasoning. |
| **Seal AgentLedger Session** | | Closes the run when the agent is done (optional: auto-close does it after inactivity). |

**Remove the standard record actions** the AgentLedger ones replace. While the
standard Update Record action is available, the agent can change data without
logging it.

Agents must be deactivated to be edited; activate them again afterwards.

### 3. Instructions

Example for a case escalation subagent:

```text
This agent keeps an AgentLedger activity log. Use Agent Id "CaseEscalationAgent" in every AgentLedger action.

1. Read the Case with "Get Record (AgentLedger)": the Case Id, and Fields "Subject, Status, Priority".
2. Decide: the Case qualifies for escalation if Priority is High and Status is not Escalated.
   Record your decision with "Record Agent Action": Action Type "Decision", Related Record Id = the Case Id,
   the decision in Output Result, and why in Reasoning. If a rule of the escalation policy applied,
   name it in Policy Reference.
3. If it qualifies, ask the user to confirm. If they confirm, change it ONLY with "Update Record (AgentLedger)":
   the Case Id, Field Values {"Status": "Escalated"}, and your reasoning.
4. Before you finish, call "Seal AgentLedger Session" with the Session Id returned by the AgentLedger actions.
```

The same pattern works for any object: read with Get Record, record the
decision, change with Update or Create Record.

**Action types** for Record Agent Action: Recommendation, Decision,
Human_Response, Query, Validation, Calculation, Create, Update, Data_Change,
Escalation, Tool_Call, Delete, Error.

### 4. Settings for the agent

On **AgentLedger Setup → Agents → Edit**: whether to record the agent, its mode,
what to do if a change cannot be logged, and its policy reference and policy
text.

## Modes

| Mode | Users see | AgentLedger also |
| --- | --- | --- |
| **Activity Log** (default) | The timeline | Hashes and chains every entry, without showing it |
| **Tamper-Evident** | The timeline, an integrity badge and Verify | Rolls back a change that cannot be logged (by default) |
| **Tamper-Evident + Anchored** | As above | Anchors each closed run externally (coming next) |

Each run keeps the mode it started with. The ledger is append-only in every
mode: entries cannot be edited or deleted, and protected run fields cannot be
changed.

## What is stored

**Agent Run** (`Agent_Audit_Session__c`), one per conversation or task:
agent, related record and object, started by, status (Active, Closed,
Incomplete), mode, integrity (Not Checked, Verified, Tampered) with Last
Verified At, entry count, fingerprint (Merkle root), agent version, instructions
hash, policy reference and policy hash.

**Agent Run Entry** (`Agent_Audit_Record__c`), one per step: type, summary,
reasoning, input and output, target record and object, field changes (before
and after), capture method (Recorded Action, Agent Script, Change Detector,
Reported by Agent), exact timestamp, turn, agent version, instructions hash,
policy reference and hash, entry hash and previous hash.

**Agent Instructions Snapshot** (`Agent_Instructions_Snapshot__c`): the exact
instructions an agent ran with, once per distinct version, found by its hash.

**AgentLedger Setting** (`AgentLedger_Setting__mdt`): the `Org_Default` record
and one record per agent. Custom metadata, so settings deploy between orgs.

## Integrity

- **Entry hash (v2):** `SHA-256("agentledger/record-hash/v2\n" + canonical JSON)`
  of the entry (RFC 8785, keys sorted), the same rule as the open-source
  libraries. The timestamp is the stored text, so hashes do not depend on time
  zones. Tests check Apex against vectors from the npm library.
- **Chain:** each entry stores the previous entry's hash.
- **Fingerprint:** when a run closes, a Merkle root (RFC 6962 style) over all
  entry hashes.
- **Verify:** recomputes every hash, the chain and the root, and records the
  result and its time. A run found Tampered says so until a later check finds it
  intact again.
- **Runs from before v2** keep verifying with the original (v1) rules, in the
  time zone of the user who recorded them.
- **Protection:** triggers block creating, editing or deleting ledger records
  outside AgentLedger. For testing tamper detection, the **AgentLedger Tamper
  Testing** permission set allows editing entries; verification still detects
  every edit. Do not assign it in production.

## Access

Runs are private. Whoever can read a record can see and verify what agents did
to it (Salesforce's own record access decides). A field change is shown only if
the viewer can read that field.

| Permission set | For |
| --- | --- |
| AgentLedger Admin | Admins: every run (read-only), the AgentLedger app and Setup page |
| AgentLedger User | People who use agents or own records: the timeline, Verify, the actions |
| AgentLedger Agent | The user a service agent runs as: the actions |
| AgentLedger Tamper Testing | Testing only |

## Auto-close

An hourly job closes runs with no activity for longer than the auto-close time
(default 30 minutes): a run with entries is sealed, and either way it is marked
**Incomplete**, so a missing close is visible. Turn it on or off, or run it now,
on the Setup page.

## Development

```bash
node scripts/deploy.mjs <org> --validate   # every test, no deploy
node scripts/deploy.mjs <org>              # every test, then deploy
node scripts/make-permission-sets.mjs      # regenerate permission sets from the metadata
node scripts/make-hash-vectors.mjs         # regenerate hash vectors from the npm library
```

The deploy script pauses the auto-close job during the deploy and resumes it.
`make-hash-vectors.mjs` needs `npm install --prefix scripts/.vectors @vluthra/agent-ledger@0.2.0`.

| Test class | Covers |
| --- | --- |
| AgentLedgerTest, AgentLedgerActionsTest, RecordAuditTrailControllerTest | Core engine and the original actions |
| AgentLedgerV2Test, AgentLedgerHashVectorsTest | v2 hashing, time zones, cross-checks with the npm library |
| AgentLedgerGuardTest | Append-only ledger, lifecycle and integrity |
| AgentLedgerSettingsTest | Settings and modes |
| AgentLedgerRecordedActionsTest | Recorded actions, automatic runs, auto-close |
| AgentLedgerPolicyTest | Agent version, instructions and policy capture; access |
| AgentLedgerUiTest | Timeline, Agent Activity and Setup pages |
