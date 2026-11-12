# AgentLedger for Agentforce: Design

Status: **draft for review** (2026-11-08). Nothing here is built yet. Sections
marked **Spike** depend on platform behavior we will confirm by test before
building on it.

## 1. What we are building

**An activity log for every Agentforce run, shown on the records the agent
touched, with tamper evidence available for the orgs that need it.**

A record owner opens an Opportunity three weeks after an agent worked on it and
sees, in plain language: what the agent looked at, what it recommended, what it
decided and why, and exactly which fields it changed, from what to what. A
compliance team can additionally prove that this log has not been altered since
the run, including to an auditor outside Salesforce.

### Principles

1. **Visibility first.** The default experience is a readable log. Hashes,
   seals and verification appear only when an org or agent turns them on.
2. **Capture must not depend on the model remembering.** Data changes are
   recorded by code. The model is asked only for what only it knows: its
   recommendation and its reasoning.
3. **Any agent, any object, no code.** Configuration, not development.
4. **Cheap to run.** No extra billable agent action for anything code can
   record on its own.
5. **Honest claims.** The UI and docs state how each entry was captured and
   what verification does and does not prove.

## 2. Users and what they need

| Who | Needs | Where |
| --- | --- | --- |
| Record owner, manager | What did the agent do on this record, and why | Record page timeline |
| Admin | Install, configure per org and per agent, see health | AgentLedger Setup page |
| Compliance, risk, audit | Proof the log is unaltered; evidence to hand over | Verify and Export on the run; Agent Activity page |
| Developer | Add AgentLedger to an agent with minimal change | Recorded actions, Agent Script template |

## 3. Modes

Set at org level, overridable per agent. The mode is stamped on each run when it
starts, so changing settings later never changes how an existing run is shown or
checked.

| Mode | User sees | Under the hood |
| --- | --- | --- |
| **Activity Log** (default) | Readable timeline | Entries hashed and chained, root computed at close. Nothing about it is shown. |
| **Tamper-Evident** | Timeline plus integrity badge, Verify, Export Evidence, verification history | Same hashing; edits and deletes of closed runs blocked; verification on view |
| **Tamper-Evident + Anchored** | All of the above plus "Anchored at (time) by (authority)" | The run's root is timestamped by an RFC 3161 authority (or a custom endpoint) after close |

Hashing in every mode means an org that upgrades from Activity Log keeps its
history protected from the start.

## 4. Data model

Existing API names stay (renaming custom objects breaks upgrades); labels change
to what users understand.

### 4.1 Agent Run (`Agent_Audit_Session__c`)

One per agent conversation or run.

| Field | Status | Purpose |
| --- | --- | --- |
| `Session_Id__c` | existing | UUID, used in hashes and exports |
| `Agent_Id__c` | existing | Agent API name; the key for per-agent settings |
| `Related_Record_Id__c` | existing, **indexed** | Primary record, always stored as 18 characters |
| `Related_Object__c` | new | sObject type of the related record |
| `Status__c` | existing, **values change** | Lifecycle only: Active, Closed, Incomplete (auto-closed). Legacy Sealed, Verified, Tampered read as Closed. |
| `Mode__c` | new | Mode stamped at start |
| `Hash_Version__c` | new | v1 (legacy) or v2 |
| `Started_By__c` | new | User lookup |
| `Turn_Count__c` | new | Conversation turns seen |
| `Record_Count__c`, `Merkle_Root__c`, `Start_Time__c`, `End_Time__c` | existing | Root shown as "Verification Fingerprint" in tamper modes |
| `Integrity__c`, `Last_Verified_At__c` | new | Not Checked, Verified, Tampered: result of the latest check, always shown with its time |
| `Anchor_Status__c`, `Anchor_Provider__c`, `Anchor_Time__c`, `Anchor_Token__c`, `Anchor_Error__c` | new | RFC 3161 token (base64) or custom receipt |

### 4.2 Agent Run Entry (`Agent_Audit_Record__c`)

One per step.

| Field | Status | Purpose |
| --- | --- | --- |
| `Entry_Id__c` | new | UUID generated before insert, used in the hash |
| `Action_Type__c` | existing, **values added** | Adds Recommendation, Data Change, Human Response, Error; existing values kept. Shown as friendly labels. |
| `Summary__c` | new | One-line headline for the timeline |
| `Reasoning__c`, `Input_Context__c`, `Output_Result__c` | existing | Why, what was considered, what was produced |
| `Target_Record_Id__c`, `Target_Object__c` | new, **indexed** | The record this step read or changed (may differ from the run's related record) |
| `Field_Changes__c` | new | JSON list of field, before, after |
| `Capture_Method__c` | new | Recorded Action, Agent Script, Change Detector, Reported by Agent. Shown on each entry. |
| `Timestamp_Text__c` | new | The exact ISO 8601 UTC string with milliseconds that is hashed (fixes the time zone and precision bugs) |
| `Turn_Number__c` | new | Which conversation turn |
| `Sequence_Number__c`, `Record_Hash__c`, `Previous_Hash__c`, `Agent_Id__c`, `Action_Timestamp__c` | existing | |

A run that touches several records appears on each of them: the timeline shows
runs related to the record plus runs with entries targeting it.

### 4.3 What the agent acted under (added after the CACM review)

Reviewers asked how an investigator, months later, can tell which policy was in
force when the agent acted. Runs and entries therefore carry, captured by code
when the run starts:

| Field | Source |
| --- | --- |
| `Agent_Version__c` | The Agentforce agent and its active version (`GenAiPlannerDefinition`, `BotVersion`) |
| `Instructions_Hash__c` | SHA-256 (tag `agentledger/agent-instructions/v1`) of every subagent's label, description, scope and instructions, found through `GenAiPlannerFunctionDef` |
| `Policy_Reference__c` | The agent's AgentLedger Setting, or passed by the agent (Start, Record Agent Action) |
| `Policy_Hash__c` | SHA-256 (tag `agentledger/policy/v1`) of the policy text in the agent's setting |

Entry hashes cover these fields, so a step cannot later be made to cite a
different policy. The instruction text is kept once per distinct hash in
`Agent_Instructions_Snapshot__c` (created only by AgentLedger, never changed),
so the investigator can read exactly what was in force. Capture never blocks a
run: if the agent definition cannot be read, the fields stay blank.

### 4.4 Verification Log (`Agent_Run_Verification__c`, new)

Child of a run, tamper modes only: who verified, when, result, failing checks.
This answers "was it ever found tampered", which the current-state check alone
cannot.

## 5. Capture: how nothing is skipped

| Layer | What it captures | Guarantee | Works with |
| --- | --- | --- | --- |
| **1. Recorded actions** | Lookups, creates, updates, with before and after values | The work and its log entry commit in the same transaction. If the entry cannot be written, the change rolls back (configurable). | Every agent |
| **2. Agent Script template** | Run start (`before_reasoning`), an entry after every action (`run` chaining), turn close (`after_reasoning`) | Executed by code on every request, not chosen by the model | Agents built with Agent Script |
| **3. Change detector** | Any change to watched objects made in an agent run without a matching entry | Backstop: flags "unrecorded change" entries | See Spike S1 |
| **4. Reported by agent** | Recommendations, decisions, reasoning | Best effort, prompt-driven; labeled as such | Every agent |

### 5.1 Recorded actions (layer 1)

Generic, object-agnostic replacements for the standard record actions, built on
the org-only `Audited*` prototype:

- **Get Record (AgentLedger)**: reads fields, logs a Lookup entry.
- **Update Record (AgentLedger)**: takes a record Id and field values, applies
  them with field-level security enforced, logs a Data Change entry with before
  and after values.
- **Create Record (AgentLedger)**: creates a record, logs it.
- **Record Decision / Record Recommendation**: the model-reported entries,
  shaped for those two types.

**Runs are implicit.** Any AgentLedger action finds the caller's open run (same
user, same agent, recent activity) or starts one. Agents no longer have to call
Start, and forgetting to close a run is handled by auto-close (5.4). The explicit
Start, Record and Seal actions remain for existing agents.

### 5.2 Agent Script template (layer 2)

A ready-to-copy `.agent` snippet and docs: `before_reasoning` ensures a run is
open; each business action carries `run @actions.agentledger_log` with its
outputs; `after_reasoning` closes the turn.

### 5.3 Change detector (layer 3)

A trigger handler on watched objects. Triggers are compiled per object, so the
package ships handlers for common standard objects (Account, Contact, Lead,
Opportunity, Case) and the docs give a one-line trigger for any other object.

### 5.4 Reconciliation with independent histories (added after the CACM review)

Cryptographic checks cannot find steps that were never recorded. As a check on
completeness that does not rely on the agent, a reconciliation report compares
Data Change entries with Salesforce's own history (Field History Tracking or
Shield Field Audit Trail) for watched objects, and lists changes made during a
run that have no matching entry. Planned for Phase 2, next to the change
detector.

### 5.5 Closing runs

- Agent Script: closed by `after_reasoning` logic on conversation end.
- Otherwise: a scheduled job closes runs inactive longer than the configured
  time (default 30 minutes) and marks them **Incomplete (auto-closed)** in tamper
  modes, so a missing close is visible rather than silent.

## 6. Integrity

### 6.1 Hash v2, compatible with the open-source library

The same rules as `@vluthra/agent-ledger` v2 ([SIGNING.md](https://github.com/cluthrv/agentledger/blob/main/SIGNING.md)), so an exported run
verifies with `verifyExportedSession` (npm) or `verify_exported_session` (PyPI):

- record hash = `SHA-256("agentledger/record-hash/v2\n" + RFC 8785 canonical JSON)`
  over `id`, `sessionId`, `sequenceNumber`, `timestamp`, `agentId`,
  `actionType`, `input`, `output`, `reasoning`, `metadata`, `previousHash`;
- `input` and `output` are objects of the stored text values; `metadata` holds
  summary, target, field changes and capture method;
- Merkle tree: RFC 6962 style (domain-separated leaves and nodes, odd node
  carried up);
- timestamps hashed from `Timestamp_Text__c`, never from a formatted DateTime.

Canonical JSON is implemented in Apex (string escaping and UTF-16 key order) and
tested against vectors generated by the npm library, so both sides produce the
same bytes.

### 6.2 Legacy v1 runs

Existing runs keep verifying with v1. The v1 timestamp is formatted in the time
zone of the user who created the run (`CreatedBy.TimeZoneSidKey`), so a verifier
anywhere gets the same answer.

### 6.3 Protection inside the org

- Entries cannot be edited; closed runs cannot be reopened or have hashed fields
  changed (trigger-enforced, AgentLedger code bypasses only for its own writes).
- Deletion only through the retention job, which can require an export first.
- Verification runs on view in tamper modes and is logged; the badge always
  shows when it last ran.

A user with full admin rights can still disable or work around any in-org
control. That is what export and anchoring address, and the docs say so.

### 6.4 Selective disclosure (added after the CACM review)

- **One entry with its proof:** export a single entry, its Merkle proof and the
  run's anchor token, so an auditor can verify that one decision without seeing
  the rest of the run.
- **Salted commitments:** for fields whose values must not be stored, store a
  salted hash instead of "(not stored)", so the value stays out of the log but
  can be proven to match if it is disclosed later.

Planned for Phase 3.

### 6.5 Export Evidence

Downloads the run as JSON in the library's `ExportedSession` shape, with the
anchor token when present. An auditor verifies it offline:
`npx @vluthra/agent-ledger verify` or `python -m agentledger verify` (0.3.0),
and the RFC 3161 token with `openssl ts -verify`.

Built (November 2026): `AgentLedgerEvidence`. Each record is
`HashChainService.entryContentV2` plus the stored hash, so the verifiers
recompute from the file alone; a `salesforce` block (org, run, exporter) is
ignored by them. Values of fields the exporter cannot read are replaced by
`[hidden]` (with the summary, request and result of that change, which repeat
the values) and listed in `salesforce.hiddenFields`; those entries do not
verify, by design. Checking real exports with the published libraries found
that the Python verifier rejected action types outside its enum ("Query",
"Data_Change"); 0.3.0 keeps unknown types as strings.

### 6.6 Hardening (November 2026)

`hardening/` installs the package in a clean org and exercises it as an admin,
a viewer and an agent user (75 checks). Findings:

- **An upgrade reset the org's settings.** The package shipped the
  `Org_Default` custom metadata record, and installing a new version
  overwrote the customer's copy (Tamper-Evident and 45 minutes became Activity
  Log and 30). The record is no longer shipped; the code already falls back to
  built-in defaults and the Setup page creates the record on first save.
  Upgrading from a version that shipped it keeps the customer's record.
- **About 45 entries per transaction** (2 SOQL each); see GUIDE Limits.
- **No unlogged change on any failure path:** an invalid field, a validation
  rule, a deleted record, bad JSON, or a failed log entry in a tamper-evident
  run leaves the record unchanged and nothing logged; Activity Log with
  Continue keeps the change and reports it as not logged.
- **Access:** a viewer gets an empty timeline, and no export or verify, for a
  record they cannot read; values of a field they cannot read appear nowhere;
  an agent user cannot read or change records outside its own access, and
  refused attempts leave no entries.
- Standard and Platform users cannot run anonymous Apex, so the user scenarios
  are Apex tests that impersonate the users.

## 7. Anchoring

| Provider | How | Notes |
| --- | --- | --- |
| None | | Default |
| RFC 3161 timestamp authority | Queueable callout after close via a Named Credential; DER request built in Apex over the root; token stored on the run | Presets for public TSAs (to be confirmed which are free for this use), or any URL |
| Custom endpoint | POST `{sessionId, root, agentId, recordCount}` to a Named Credential | For a customer's own service, or a relay to a blockchain anchor such as the Arbitrum AnchorRegistry |

No URLs or keys in code: endpoints and credentials live in Named Credentials the
admin creates. A **Send test timestamp** button checks the setup.

## 8. Configuration

### 8.1 Storage

Custom metadata type `AgentLedger_Setting__mdt` (already prototyped in the Dev
Hub org): one `Org_Default` record plus one record per agent that overrides it.
Custom metadata deploys between sandboxes and production like any other
configuration. The Setup page writes it through the Metadata API (an admin with
Customize Application).

### 8.2 AgentLedger Setup page

| Section | Settings |
| --- | --- |
| General | Enabled; default mode |
| Agents | Every agent in the org (read from `BotDefinition`) with enabled and mode overrides |
| Capture | Watched objects (shows which have a detector trigger); auto-close minutes; if logging fails: continue or roll back |
| Privacy | Store field values or only field names; fields never stored; retention period; export before delete |
| Anchoring | Provider; Named Credential; Send test timestamp |
| Health | Setup checklist (permission sets assigned, actions registered, component placed), open and incomplete runs, recent verification failures, last job runs |

## 9. User interface

- **Agent Activity timeline** (record page): one card per run with agent, who
  started it, when, entry count and, in tamper modes, the integrity badge with
  Verify and Export. Each entry shows an icon for its type, the summary, how it
  was captured, and expands to reasoning, inputs, outputs and a field-change
  table. Paged ("Show older runs"). Refreshes when a run updates.
- **Field-level security in the log:** a field change is shown only if the
  viewer can read that field.
- **Record access:** a user sees a run only if they can read its related record
  (checked with `UserRecordAccess`).
- **AgentLedger app:** Agent Activity home (recent runs, filters, incomplete,
  tampered), Agent Runs list, Setup page.

## 10. Permissions

| Permission set | For | Grants |
| --- | --- | --- |
| AgentLedger Admin | Admins | Setup page, all runs, verification history |
| AgentLedger User | Record owners, reviewers | Timeline, Verify, Export for records they can see |
| AgentLedger Agent | Agent users (service agents) | The actions; no direct object edit |

Run and entry objects are Private; all access goes through AgentLedger's Apex,
which enforces record access and field-level security as described above.

## 11. Packaging and install

**Scheduled jobs and upgrades.** Salesforce refuses to deploy (or upgrade a
package with) Apex while a scheduled job is pending, unless "Allow deployments
of components when corresponding Apex jobs are pending or in progress" is on in
Deployment Settings. The auto-close job schedules a dependency-free wrapper
(`AgentLedgerScheduler`, which starts the batch by name), and the Setup page
will offer to pause and resume auto-close around upgrades.


- One unlocked package (core, UI, actions, setup page), no namespace for the
  open-source release; the `aledger` namespace is reserved for the AppExchange
  listing later.
- Action registrations: inside the package (Spike S2 confirmed unlocked
  packages can carry `GenAiFunction`), built in an Agentforce-shaped build org.
  Fallback until that build works: one documented deploy command, with the
  `.forceignore` bug fixed.
- First open of the AgentLedger app shows the setup checklist.
- Install tested on a fresh Agentforce Developer Edition org before each release.

## 12. Spikes

Run on 2026-11-08 in the Dev Hub org (`agentledger-dev`); spike metadata removed
afterwards.

| # | Question | Result |
| --- | --- | --- |
| S1 | Can Apex tell that a transaction is running inside an agent run? | **Open.** `System.Quiddity` has no agent value. What a trigger sees during an agent's standard Update Record action was not captured (preview `-x` produced no Apex logs). Retest with a trace flag in Phase 2, before building the change detector. |
| S2 | Can an unlocked package contain `GenAiFunction`? | **Yes.** A package version containing one action installed and registered the action (`GenAiFunctionDefinition` present). Caveat: validated builds fail in a default build org ("not available for deploy"); a releasable version needs a build org with Agentforce, probably via org shape. |
| S3 | Agent Script hooks; billing; access to the final response | `before_reasoning`/`after_reasoning` run once per turn, deterministically; `@system_variables.user_input` is available; the agent's reply is **not** exposed. Decisions are therefore captured by gating: business actions are `available when` a decision has been recorded, and `after_reasoning` logs "no decision recorded" otherwise. Billing not documented: measure in the org. |
| S4 | Does a DateTime field keep milliseconds? | **No** (sent 123 ms, stored 0). `Timestamp_Text__c` is required. |
| S5 | RFC 3161 from Apex | **Works.** DER request built in Apex (59 bytes), DigiCert returned a granted 5,995-byte token in 145 ms. DigiCert and Sectigo tokens verify with `openssl ts -verify` against the standard CA bundle; FreeTSA needs its own CA file. Presets: DigiCert, Sectigo. |

Also observed: the Case Escalation agent, given the same Case twice, decided
"no escalation required" the first time (contradicting its instructions) and
escalated the second time. AgentLedger recorded both runs, including the wrong
reasoning, which is exactly what a record owner needs to see. Its "Update"
entry was written by the model and carries no before and after values, which
recorded actions fix.

## 13. Delivery plan

| Phase | Contents |
| --- | --- |
| **1** | Bug fixes (time zone, clock, locking, 15/18 Ids, `.forceignore`), data model changes, settings and Setup page (General, Agents, Capture), recorded actions, implicit runs, auto-close, new timeline, permission sets, record access and field-level security |
| **2** | Agent Script template, change detector, privacy and retention, Agent Activity page |
| **3** | Hash v2, Export Evidence, verification log, RFC 3161 and custom anchoring, Setup page (Privacy, Anchoring, Health) |
| Later | Human override module, reconciliation with Agentforce session tracing, multi-agent run linking |

Every phase: Apex tests, LWC Jest tests, cross-language hash vectors (from
Phase 3), and an end-to-end pass with the Opportunity and Case agents in the Dev
Hub org.

## 14. Decisions requested

1. Settings in custom metadata, edited through the Setup page (recommended), or a
   simpler custom setting that cannot be deployed between orgs.
2. Implicit runs (any AgentLedger action opens a run) as the default.
3. If logging fails inside a recorded action: default to **roll back the
   change** in tamper modes and **continue** in Activity Log mode.
4. The three permission sets above.
