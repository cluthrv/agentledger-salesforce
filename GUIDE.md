# AgentLedger for Agentforce: Guide

How to connect an agent, what AgentLedger stores, and how it works.

## Connect an agent

### 1. Use the agent's API name as its Agent Id

Every AgentLedger action takes an **Agent Id**. Use the agent's API name (for
example `CaseEscalationAgent`, shown on the Setup page); the instructions the
Setup page gives you already do. AgentLedger then finds the agent's definition
and records its version and instructions on every run. If an agent uses another
value, set **Agentforce Agent** for it on the Setup page.

An agent appears on the Setup page once it has been saved as an agent version.
In the new Agentforce Builder, that happens when you click **Commit Version**;
**Save** alone keeps a draft.

### 2. Give the agent the AgentLedger actions

Add them to the subagent that does the work, not to the Agent Router. In the
classic builder: the subagent → **Actions** → **New → Add from Asset Library**.
In the new Agentforce Builder: the subagent → **+** → **Add Action for
Reasoning**.

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

Custom actions (flows, Apex) can stay: AgentLedger works alongside them, and the
change detector logs the changes they make on watched objects.

**Editing a live agent.** Classic builder: deactivate the agent, edit, activate
it again. New Agentforce Builder: click **New Version**, edit, then **Commit
Version** and activate that version.

### 3. Settings and instructions

On **AgentLedger Setup → Agents → Edit**: whether to record the agent, its mode,
what to do if a change cannot be logged, and its policy reference and policy
text. Click **Save agent settings**.

The panel then shows **Instructions for this agent**, built from those settings.
Click **Copy instructions** and add them to the subagent, next to its own
instructions:

- **Classic builder:** as a separate instruction (**Add Instruction**).
- **New Agentforce Builder:** at the end of the subagent's **Reasoning
  Instructions**.

Leave the agent's business instructions as they are. The AgentLedger
instructions only say which actions to use and what to record, so the same
block works for any agent. For a case escalation agent with a policy set, they
read:

```text
AgentLedger activity log. Follow these rules in addition to your other instructions. Use Agent Id "CaseEscalationAgent" in every AgentLedger action, and pass the Session Id returned by the first AgentLedger action to every later AgentLedger action.
- To read a record, use "Get Record (AgentLedger)".
- To change a record, use ONLY "Update Record (AgentLedger)"; to create one, use ONLY "Create Record (AgentLedger)". Always include your reasoning.
- Whenever you check a rule or criterion, call "Record Agent Action" with Action Type "Validation": the result and the actual value in Output Result, why in Reasoning, and the record's Id as Related Record Id.
- When you reach a decision or recommendation, call "Record Agent Action" with Action Type "Decision" or "Recommendation": the outcome in Output Result and why in Reasoning. Put "Case Escalation Policy v1" in Policy Reference.
- When you hand off to a person or escalate, call "Record Agent Action" with Action Type "Escalation" saying to whom and why.
- When you have finished the task, call "Seal AgentLedger Session" before your final reply.
```

**Action types** for Record Agent Action: Recommendation, Decision,
Human_Response, Query, Validation, Calculation, Create, Update, Data_Change,
Escalation, Tool_Call, Delete, Error.

Start in **Activity Log** mode: it logs everything and never blocks the agent.
Switch to **Tamper-Evident** once the agent's runs look right.

### 4. Check that it works

Run the agent in Builder's preview on a test record, then open the record:

- The **AgentLedger Activity** card shows a run under the agent's API name,
  with lookups and changes marked **Recorded automatically** and decisions marked
  as reported by the agent.
- A change you make yourself to the record adds nothing.
- The run is listed on the **Agent Activity** tab, and **Health** on the Setup
  page shows no warnings.

| Symptom | Cause |
| --- | --- |
| The agent is not on the Setup page | New Agentforce Builder: the version was saved but not committed. Commit it and refresh. |
| Runs show "Unidentified agent" | The agent changed a record without the AgentLedger actions: remove the standard Update Record action, check the instructions are pasted. |
| The run is under a different Agent Id | Set **Agentforce Agent** for that Agent Id on the Setup page. |
| An action fails with an access error | The user the agent runs as needs **AgentLedger User**, or **AgentLedger Agent** for a service agent. |
| Some steps are missing | The instructions were not pasted or were edited: copy them again. |

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
and after; fields an update set as a knock-on effect, such as an Opportunity's
Probability following its Stage, are marked automatic), capture method (Recorded Action, Agent Script, Change Detector,
Reported by Agent), exact timestamp, turn, agent version, instructions hash,
policy reference and hash, entry hash and previous hash.

**Agent Instructions Snapshot** (`Agent_Instructions_Snapshot__c`): the exact
instructions an agent ran with, once per distinct version, found by its hash.
For an agent built in the new Agentforce Builder, Salesforce keeps the
subagents' reasoning instructions in the agent's script, which Apex cannot read.
Its snapshot holds the agent-level instructions and subagent descriptions, and
says so in its `coverage` field; the agent version recorded on the run (for
example `Opportunity_Qualification_Agent v2 (Active)`) identifies the locked
version whose full instructions can be read in Builder.

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
- **Export:** the Export button on a tamper-evident run downloads it as JSON in
  the open-source libraries' exported-session format: each entry exactly as
  hashed, with its hash, and the run's fingerprint. Verify it anywhere:

  ```bash
  npx @vluthra/agent-ledger verify agentledger-AAS-0047.json   # Node.js
  python -m agentledger verify agentledger-AAS-0047.json      # pip install vluthra-agent-ledger
  ```

  Both need version 0.3.0 or later. Whoever can see a run can export it. Values of fields the
  exporting user cannot read are left out; those entries are listed in the file
  (`salesforce.hiddenFields`) and do not verify. Runs from before v2 cannot be
  exported. `node scripts/check-export.mjs <org> [run names]` exports runs from
  an org and verifies them with the published npm library.
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

## Changes made outside AgentLedger

**Change detector.** Triggers on Account, Contact, Lead, Opportunity and Case
log a change an agent makes without an AgentLedger action (for example through
the standard Update Record action or a Flow action). The entry goes into the
user's open run for that record, or their most recent open run, or a new run for
"Unidentified agent", and is labelled **Detected: not logged by the agent**:
it has before and after values but no reasoning. In Tamper-Evident mode
(roll back), a change the detector cannot log is refused.

How it knows: an Apex action run by an agent executes with the request type
`INVOCABLE_ACTION`; a Flow action run by an agent arrives through the agent
runtime's call to `/services/data/vNN.N/support/functions/`. A person's change
through the UI or API, and a Flow called through the Actions API, are neither. AgentLedger's own actions mark their changes, so
they are not logged twice. Bulk changes log the first 20 records one by one and
the rest in one entry.

For another object, add a trigger:

```apex
trigger MyObjectAgentLedger on My_Object__c (after insert, after update, after delete) {
    AgentLedgerChangeDetector.handle();
}
```

The org default's **Watched objects** limits detection to the objects listed;
empty means every object with a detector trigger.

**Check history.** The **Check history** button on a run compares it with
Salesforce's own Field History: the tracked field changes made by the run's user
on the records it touched, while it ran. Each is looked up in the log; any the
log does not have are listed. This does not rely on AgentLedger's capture. It
covers fields with Field History Tracking turned on; objects without field
history are named. A person's own edit during the run is listed too, for the
reviewer to judge.

## Limits

- **Entries per transaction:** each entry costs 2 SOQL queries, so about 45
  entries fit in one Apex transaction (Salesforce allows 100 queries). Agents
  call one action per transaction; code that logs many steps at once should
  split them across transactions.
- **Run size:** a run of 200 entries seals in under 0.1 s of CPU, verifies in
  about 0.3 s and exports as about 150 KB of JSON.
- **Concurrent writers:** steps written to one run at the same time are
  serialized by a row lock; the chain stays linear.

## Development

```bash
node scripts/deploy.mjs <org> --validate   # every test, no deploy
node scripts/deploy.mjs <org>              # every test, then deploy
node scripts/make-permission-sets.mjs      # regenerate permission sets from the metadata
node scripts/make-hash-vectors.mjs         # regenerate hash vectors from the npm library
```

The deploy script pauses the auto-close job during the deploy and resumes it.

### Hardening suite

Exercises an installed package in a clean org, the way a customer would get
there, and prints PASS or FAIL per check:

```bash
node hardening/setup.mjs <dev-hub> al-hard <earlier 04t> <new 04t>   # org, install, use, upgrade, users
node hardening/run.mjs al-hard                                       # the scenarios
node scripts/check-export.mjs al-hard <run names>                    # verify exports with the npm library
```

Setup installs the earlier version, sets the org default and records a run,
upgrades, and checks that settings and runs survived. It then deploys test-only
metadata (`hardening/main`: a private object with a field one user cannot read,
a validation rule, a trigger that can force a log failure, and agent settings
per mode) and creates a viewer and an agent user. The scenarios cover agent
flows on Case, Account, Contact, Lead, Opportunity and a custom object; failed
changes and failed log entries in each mode; recording off and closed runs;
volume; concurrent writers; and, as Apex tests that run as those users, what a
viewer without access sees and what an agent user can reach. `ONLY=volume,access`
runs a subset.
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
