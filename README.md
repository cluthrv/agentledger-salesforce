# AgentLedger for Agentforce

**See what your AI agents did on every record, and prove it was not changed afterwards.**

AgentLedger keeps an activity log of every Agentforce run on the records the
agent touched: what it looked at, what it decided and why, and exactly which
fields it changed, from what to what. A record owner who wonders three weeks
later why an agent escalated a Case, or did not, finds the answer on the Case
itself.

For teams that need more than visibility, AgentLedger can also make that log
**tamper-evident**: every step is hashed and chained, each run is sealed, and
anyone can verify later that nothing was changed, including outside Salesforce
with the open-source verifiers.

Open source (MIT), native to Salesforce, no external services.

## What you get

| | |
| --- | --- |
| **Activity timeline** | A component for any record page: each agent run, its steps in plain language, field changes with before and after values, and whether each step was recorded automatically or reported by the agent. |
| **Recorded actions** | Get, Update and Create Record (AgentLedger): drop-in replacements for the standard record actions. The change and its log entry are written together, so a change made through them is always logged. Fields the change sets as a knock-on effect (a stage's default Probability, a flow or trigger) are logged too, marked as set automatically, and so are changes that automation makes to other watched records in the same transaction. |
| **What the agent acted under** | Every run records the agent version, a fingerprint of its instructions (the full text is kept once per version) and the policy it acted under. For agents built in the new Agentforce Builder, the captured instructions are the agent-level instructions and subagent descriptions; subagent reasoning instructions are read in that agent version in Builder. |
| **Modes** | Activity Log (default), Tamper-Evident, or Tamper-Evident + Anchored, set for the org and per agent. |
| **Change detector** | Triggers on Account, Contact, Lead, Opportunity and Case log changes an agent makes without an AgentLedger action, such as through the standard Update Record action. They are marked "Detected: not logged by the agent". |
| **Check history** | Compares a run with the field changes Salesforce recorded in Field History during it, and lists any the log does not have. |
| **Export and verify anywhere** | Export downloads a run as JSON. Anyone can verify it outside Salesforce with `npx @vluthra/agent-ledger verify` or `python -m agentledger verify`. |
| **Agent Activity page** | Recent runs across the org, filtered by status, integrity or agent. |
| **Setup page** | Settings for the org and each agent, health, and the auto-close job, without Setup menus. |

## How it works

```text
Agent runs ──► Get / Update / Create Record (AgentLedger) ──► change + log entry, one transaction
           └─► Record Agent Action ──────────────────────────► decisions, recommendations, reasoning

Each entry: summary · reasoning · field changes · how it was captured · agent version · policy
            └─ hashed (SHA-256, canonical JSON) and chained to the entry before it

Run closes (agent, or auto-close after inactivity) ──► Merkle root over all entries
Verify (tamper-evident modes) ──► recompute hashes, chain and root ──► Verified / Tampered
Export ──► run as JSON ──► npx @vluthra/agent-ledger verify run.json (outside Salesforce)
```

Runs open automatically on the first AgentLedger action, so agents do not need a
Start step, and runs left open are closed and marked **Incomplete** by an hourly
job.

## What it does and does not prove

- **It proves** that the recorded steps have not changed since they were
  recorded (tamper-evident modes), and records which steps were captured by code
  and which were reported by the agent.
- **It does not prove** that the agent's decision was correct, or that its
  stated reasoning is how the model actually decided: the reasoning is the
  agent's own explanation.
- **Completeness depends on capture.** Changes made through the recorded actions
  are always logged, with the agent's reasoning. A change an agent makes through
  any other action on Account, Contact, Lead, Opportunity or Case is still
  logged by the change detector, marked as not logged by the agent. Steps the
  agent only reports (decisions, recommendations) are logged when it reports
  them. **Check history** compares a run with Salesforce's own Field History and
  lists tracked changes the log does not have.
- **Inside one org, a determined administrator** can deactivate triggers and
  rewrite records and fingerprints together. A copy exported earlier and kept
  outside the org shows such a rewrite; external anchoring (coming next) shows it
  without a copy.

## Install

Requires Agentforce in the org.

**Package.** Install the latest version, 0.1.0-11, from this link (for a
sandbox, use `test.salesforce.com` instead of `login.salesforce.com`), and choose
**Install for Admins Only**:

```text
https://login.salesforce.com/packaging/installPackage.apexp?p0=04tgK000000aoPhQAI
```

This is a beta version: Salesforce installs it in sandboxes, scratch orgs and
Developer Edition orgs, not in production, until a released version is
promoted.

**From source** (Salesforce CLI):

```bash
git clone https://github.com/cluthrv/agentledger-salesforce
cd agentledger-salesforce
sf org login web --alias my-org
node scripts/deploy.mjs my-org          # runs every test, then deploys
```

Then, in the org:

1. **Assign permission sets** (Setup → Permission Sets):
   - **AgentLedger Admin** to admins.
   - **AgentLedger User** to everyone who uses agents or owns records agents work on.
   - **AgentLedger Agent** to the user a service agent runs as.
2. **Add the component:** in Lightning App Builder, add **AgentLedger Activity**
   to the record page of each object your agents work on.
3. **Open the AgentLedger app** (App Launcher → AgentLedger) → **AgentLedger
   Setup**: choose the default mode, then **Edit** each agent to set its mode and
   policy. Auto-close starts on its own the first time you turn it on.
4. **Give your agents the AgentLedger actions**, then paste the instructions the
   Setup page gives you for each agent (**Edit** → **Copy instructions**) into
   its subagent. Works for agents in the classic builder and the new Agentforce
   Builder: see [GUIDE.md](GUIDE.md#connect-an-agent).

**Upgrading:** settings are kept: the package does not ship the org default
record, which the Setup page creates on its first save. Salesforce does not
deploy Apex while a scheduled job is pending.
`scripts/deploy.mjs` pauses and resumes the auto-close job for you; when
installing another way, turn auto-close off on the Setup page first and on again
afterwards.

## Documentation

- [GUIDE.md](GUIDE.md): connecting an agent, the data model, hashing,
  permissions, settings, testing.
- [DESIGN.md](DESIGN.md): design decisions, what was tested on the platform, and
  what comes next.
- Hashing and verification rules shared with the open-source libraries:
  [SIGNING.md](https://github.com/cluthrv/agentledger/blob/main/SIGNING.md).

## Related

AgentLedger for Agentforce is part of [AgentLedger](https://github.com/cluthrv/agentledger),
which also provides the [npm](https://www.npmjs.com/package/@vluthra/agent-ledger)
and [PyPI](https://pypi.org/project/vluthra-agent-ledger/) libraries and an MCP
gateway. Runs recorded in Salesforce use the same v2 hashing, so they verify
with those libraries.

## License

MIT. See [LICENSE](LICENSE).
