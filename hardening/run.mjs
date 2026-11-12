// Hardening suite: exercises an installed AgentLedger in a real org, as an
// admin, a user with limited access, and an agent user, and prints PASS/FAIL
// per check. Setup (org, package, test metadata, users) is in hardening/setup.mjs.
//
//   node hardening/run.mjs <admin-alias>
import fs from 'node:fs';
import os from 'node:os';
import path from 'node:path';
import { execFile } from 'node:child_process';
import { promisify } from 'node:util';

const execFileP = promisify(execFile);
const [ADMIN] = process.argv.slice(2);
if (!ADMIN) {
  console.error('usage: node hardening/run.mjs <admin-alias>');
  process.exit(2);
}

// ── Running Apex ──

const PRELUDE = `
void check(String name, Boolean ok, Object detail) {
    System.debug('CHECK ' + (ok == true ? 'PASS' : 'FAIL') + ' ' + name + ' :: ' + (detail == null ? 'null' : String.valueOf(detail)).replace('\\n', ' '));
}
void out(String key, Object value) { System.debug('OUT ' + key + ' ' + String.valueOf(value)); }
CreateRecordAgentLedgerAction.Result create(String agent, String obj, String values, Id sessionId, String reasoning) {
    CreateRecordAgentLedgerAction.Request r = new CreateRecordAgentLedgerAction.Request();
    r.agentId = agent; r.objectApiName = obj; r.fieldValues = values; r.sessionId = sessionId; r.reasoning = reasoning;
    return CreateRecordAgentLedgerAction.execute(new List<CreateRecordAgentLedgerAction.Request>{ r })[0];
}
UpdateRecordAgentLedgerAction.Result upd(String agent, Id recordId, String values, Id sessionId, String reasoning) {
    UpdateRecordAgentLedgerAction.Request r = new UpdateRecordAgentLedgerAction.Request();
    r.agentId = agent; r.recordId = recordId; r.fieldValues = values; r.sessionId = sessionId; r.reasoning = reasoning;
    return UpdateRecordAgentLedgerAction.execute(new List<UpdateRecordAgentLedgerAction.Request>{ r })[0];
}
GetRecordAgentLedgerAction.Result getRec(String agent, Id recordId, String fields, Id sessionId) {
    GetRecordAgentLedgerAction.Request r = new GetRecordAgentLedgerAction.Request();
    r.agentId = agent; r.recordId = recordId; r.fields = fields; r.sessionId = sessionId; r.reasoning = 'Hardening lookup';
    return GetRecordAgentLedgerAction.execute(new List<GetRecordAgentLedgerAction.Request>{ r })[0];
}
RecordAgentActionAction.Result note(String agent, Id sessionId, Id related, String type, String reasoning) {
    RecordAgentActionAction.Request r = new RecordAgentActionAction.Request();
    r.agentId = agent; r.sessionId = sessionId; r.relatedRecordId = related; r.actionType = type;
    r.inputContext = 'hardening input'; r.outputResult = 'hardening output'; r.reasoning = reasoning;
    return RecordAgentActionAction.execute(new List<RecordAgentActionAction.Request>{ r })[0];
}
Id seal(Id sessionId) {
    SealAgentLedgerSessionAction.Request r = new SealAgentLedgerSessionAction.Request();
    r.sessionId = sessionId;
    return SealAgentLedgerSessionAction.execute(new List<SealAgentLedgerSessionAction.Request>{ r })[0].success == true ? sessionId : null;
}
`;
const ADMIN_PRELUDE = `
Integer entries(Id runId) { return [SELECT COUNT() FROM Agent_Audit_Record__c WHERE Audit_Session__c = :runId]; }
Id runOf(Id entryId) { return [SELECT Audit_Session__c FROM Agent_Audit_Record__c WHERE Id = :entryId].Audit_Session__c; }
`;

const results = [];
const outputs = {};

async function apex(label, user, body, vars = {}) {
  // Each scenario reports its own exception, with the line, as a failed check:
  // a failed anonymous run returns no debug log.
  const wrapped = `try {
${body}
} catch (Exception e) {
    check('exception', false, e.getTypeName() + ': ' + e.getMessage() + ' at ' + e.getStackTraceString());
}
`;
  let code = PRELUDE + (user === ADMIN ? ADMIN_PRELUDE : '') + wrapped;
  for (const [k, v] of Object.entries(vars)) code = code.replaceAll(`{{${k}}}`, String(v));
  const file = path.join(os.tmpdir(), `al-hardening-${process.pid}-${Math.random().toString(36).slice(2)}.apex`);
  fs.writeFileSync(file, code);
  if (process.env.DUMP) fs.writeFileSync(path.join(process.env.DUMP, `${label}-${Math.random().toString(36).slice(2, 6)}.apex`), code);
  let json;
  try {
    const { stdout } = await execFileP('sf', ['apex', 'run', '-f', file, '-o', user, '--json'],
      { shell: process.platform === 'win32', maxBuffer: 64 << 20 });
    json = JSON.parse(stdout);
  } catch (e) {
    json = e.stdout ? JSON.parse(e.stdout) : { result: { success: false, exceptionMessage: e.message } };
  } finally {
    fs.unlinkSync(file);
  }
  const r = json.result ?? {};
  const logs = r.logs ?? '';
  for (const m of logs.matchAll(/\|DEBUG\|CHECK (PASS|FAIL) (\S+) :: (.*)/g)) {
    results.push({ scenario: label, pass: m[1] === 'PASS', name: m[2], detail: m[3].trim() });
  }
  for (const m of logs.matchAll(/\|DEBUG\|OUT (\S+) (.*)/g)) outputs[m[1]] = m[2].trim();
  if (!r.success) {
    // Report the line within the scenario, not within prelude + scenario.
    const preludeLines = code.slice(0, code.indexOf(body.trimStart().slice(0, 40))).split('\n').length - 1;
    const where = r.line ? ` (scenario line ${r.line - preludeLines})` : '';
    const stack = r.exceptionStackTrace ? ` ${r.exceptionStackTrace}` : '';
    results.push({ scenario: label, pass: false, name: 'script', detail: (r.compileProblem || r.exceptionMessage || json.message) + where + stack });
  }
  return logs;
}

// ── Scenarios ──

// One full agent flow per object: create, look up, update, decide, seal, verify.
const OBJECTS = [
  ['Case', '{"Subject":"Hardening case","Status":"New","Origin":"Web","Priority":"High"}', '{"Status":"Escalated"}', 'Status'],
  ['Account', '{"Name":"Hardening Account","Industry":"Banking"}', '{"Industry":"Insurance"}', 'Industry'],
  ['Contact', '{"LastName":"Hardening","Title":"Analyst"}', '{"Title":"Lead Analyst"}', 'Title'],
  ['Lead', '{"LastName":"Hardening","Company":"Acme","Status":"Open - Not Contacted"}', '{"Status":"Working - Contacted"}', 'Status'],
  ['Opportunity', '{"Name":"Hardening deal","StageName":"Prospecting","CloseDate":"2027-03-31","Amount":1000}', '{"StageName":"Qualification","Amount":2500.5}', 'StageName'],
  ['Hardening_Item__c', '{"Name":"Item","Amount__c":10,"Status__c":"New","Secret__c":"s1"}', '{"Status__c":"Done","Amount__c":12.25}', 'Status__c'],
];
const FLOW = `
String obj = '{{OBJ}}';
CreateRecordAgentLedgerAction.Result c = create('HardenTE', obj, '{{CREATE}}', null, 'Create for hardening');
check(obj + '.create', c.success == true && c.logged == true && c.recordId != null, c);
Id runId = c.sessionId;
GetRecordAgentLedgerAction.Result g = getRec('HardenTE', c.recordId, null, runId);
check(obj + '.get', g.success == true && g.sessionId == runId && g.recordJson != null, g.errorMessage);
UpdateRecordAgentLedgerAction.Result u = upd('HardenTE', c.recordId, '{{UPDATE}}', runId, 'Update for hardening');
check(obj + '.update', u.success == true && u.logged == true && String.isNotBlank(u.changes), u);
SObject after = Database.query('SELECT {{FIELD}} FROM ' + obj + ' WHERE Id = \\'' + c.recordId + '\\'');
Map<String, Object> want = (Map<String, Object>) JSON.deserializeUntyped('{{UPDATE}}');
check(obj + '.updatePersisted', String.valueOf(after.get('{{FIELD}}')) == String.valueOf(want.get('{{FIELD}}')), after);
RecordAgentActionAction.Result d = note('HardenTE', runId, c.recordId, 'Decision', 'Decided for hardening');
check(obj + '.decision', d.success == true && d.sequenceNumber == 3, d);
AgentAuditRecorder.sealSession(runId);
Agent_Audit_Session__c run = [SELECT Name, Status__c, Mode__c, Record_Count__c, Related_Object__c, Policy_Reference__c FROM Agent_Audit_Session__c WHERE Id = :runId];
check(obj + '.run', run.Mode__c == 'Tamper_Evident' && run.Record_Count__c == 4 && run.Policy_Reference__c == 'Hardening Policy v1', run);
check(obj + '.verify', AgentAuditRecorder.verifySession(runId).valid == true, 'verified');
Agent_Audit_Record__c ch = [SELECT Field_Changes__c, Capture_Method__c FROM Agent_Audit_Record__c WHERE Audit_Session__c = :runId AND Sequence_Number__c = 2];
check(obj + '.fieldChanges', ch.Capture_Method__c == 'Recorded_Action' && ch.Field_Changes__c.contains('"before"'), ch.Field_Changes__c);
out('run.' + obj, run.Name);
`;

// What happens to the data when a change or its log entry fails.
const FAILURES = `
Hardening_Item__c item = new Hardening_Item__c(Name = 'Failure item', Amount__c = 5, Status__c = 'New');
insert item;
Integer runsBefore = [SELECT COUNT() FROM Agent_Audit_Session__c];
Integer entriesBefore = [SELECT COUNT() FROM Agent_Audit_Record__c];

UpdateRecordAgentLedgerAction.Result a = upd('HardenTE', item.Id, '{"No_Such_Field__c": 1}', null, 'bad field');
check('fail.unknownField', a.success == false && String.isNotBlank(a.errorMessage), a.errorMessage);

UpdateRecordAgentLedgerAction.Result b = upd('HardenTE', item.Id, '{"Amount__c": -5}', null, 'validation rule');
check('fail.validationRule', b.success == false && [SELECT Amount__c FROM Hardening_Item__c WHERE Id = :item.Id].Amount__c == 5, b.errorMessage);

UpdateRecordAgentLedgerAction.Result c = upd('HardenTE', item.Id, '{"Status__c": "Changed"}', null, 'FORCE_LOG_FAILURE tamper-evident');
check('fail.logFailureRollsBack', c.success == false && [SELECT Status__c FROM Hardening_Item__c WHERE Id = :item.Id].Status__c == 'New', c);

CreateRecordAgentLedgerAction.Result d = create('HardenTE', 'Hardening_Item__c', '{"Name":"Should not exist"}', null, 'FORCE_LOG_FAILURE create');
check('fail.logFailureNoCreate', d.success == false && [SELECT COUNT() FROM Hardening_Item__c WHERE Name = 'Should not exist'] == 0, d);

check('fail.nothingLogged', [SELECT COUNT() FROM Agent_Audit_Record__c] == entriesBefore, [SELECT COUNT() FROM Agent_Audit_Record__c] - entriesBefore);

UpdateRecordAgentLedgerAction.Result e = upd('HardenALC', item.Id, '{"Status__c": "Kept"}', null, 'FORCE_LOG_FAILURE activity log, continue');
check('fail.continueKeepsChange', e.success == true && e.logged == false && [SELECT Status__c FROM Hardening_Item__c WHERE Id = :item.Id].Status__c == 'Kept', e);

GetRecordAgentLedgerAction.Result f = getRec('HardenTE', item.Id, 'Nope__c', null);
check('fail.getUnknownField', f.success == false, f.errorMessage);

Id deleted;
Hardening_Item__c gone = new Hardening_Item__c(Name = 'Gone');
insert gone; deleted = gone.Id; delete gone;
UpdateRecordAgentLedgerAction.Result g = upd('HardenTE', deleted, '{"Status__c": "x"}', null, 'deleted record');
check('fail.deletedRecord', g.success == false, g.errorMessage);

UpdateRecordAgentLedgerAction.Result h = upd('HardenTE', item.Id, 'not json', null, 'bad json');
check('fail.badJson', h.success == false, h.errorMessage);
`;

// Modes: recording off, Activity Log, unknown agent (org default), a closed run.
const MODES = `
Hardening_Item__c item = new Hardening_Item__c(Name = 'Modes item', Amount__c = 1, Status__c = 'New');
insert item;
Integer runsBefore = [SELECT COUNT() FROM Agent_Audit_Session__c];
UpdateRecordAgentLedgerAction.Result off = upd('HardenOff', item.Id, '{"Status__c": "Off"}', null, 'recording off');
check('mode.offChanges', off.success == true && [SELECT Status__c FROM Hardening_Item__c WHERE Id = :item.Id].Status__c == 'Off', off);
check('mode.offNoRun', [SELECT COUNT() FROM Agent_Audit_Session__c] == runsBefore, 'runs ' + ([SELECT COUNT() FROM Agent_Audit_Session__c] - runsBefore));

UpdateRecordAgentLedgerAction.Result al = upd('HardenALC', item.Id, '{"Status__c": "AL"}', null, 'activity log');
check('mode.activityLog', [SELECT Mode__c FROM Agent_Audit_Session__c WHERE Id = :al.sessionId].Mode__c == 'Activity_Log', al);

UpdateRecordAgentLedgerAction.Result unknown = upd('SomeOtherAgent', item.Id, '{"Status__c": "Default"}', null, 'org default');
String defaultMode = [SELECT Mode__c FROM Agent_Audit_Session__c WHERE Id = :unknown.sessionId].Mode__c;
check('mode.orgDefault', defaultMode == AgentLedgerSettings.orgDefault().mode, defaultMode);

UpdateRecordAgentLedgerAction.Result te = upd('HardenTE', item.Id, '{"Status__c": "TE"}', null, 'tamper evident');
AgentAuditRecorder.sealSession(te.sessionId);
UpdateRecordAgentLedgerAction.Result afterSeal = upd('HardenTE', item.Id, '{"Status__c": "After seal"}', te.sessionId, 'into a closed run');
check('mode.closedRunNotReused', afterSeal.success == false || afterSeal.sessionId != te.sessionId, afterSeal);
check('mode.closedRunUnchanged', entries(te.sessionId) == 1, entries(te.sessionId));
`;

// Many entries in one transaction: where the limits are.
const VOLUME_ONE_TX = `
Hardening_Item__c item = new Hardening_Item__c(Name = 'Volume item');
insert item;
Id runId = runOf(note('HardenTE', null, item.Id, 'Decision', 'volume 0').auditRecordId);
Integer n = 1;
Integer soqlPerEntry;
try {
    for (; n < {{N}}; n++) {
        Integer before = Limits.getQueries();
        note('HardenTE', runId, item.Id, 'Decision', 'volume ' + n);
        soqlPerEntry = Limits.getQueries() - before;
    }
    check('volume.oneTransaction{{N}}', entries(runId) == {{N}}, 'SOQL per entry ' + soqlPerEntry + ', CPU ms ' + Limits.getCpuTime() + ', queries ' + Limits.getQueries());
} catch (Exception e) {
    check('volume.oneTransaction{{N}}', false, 'stopped at entry ' + n + ': ' + e.getMessage());
}
out('volume.soqlPerEntry', soqlPerEntry);
`;

const VOLUME_START = `
Hardening_Item__c item = new Hardening_Item__c(Name = 'Big run item');
insert item;
Id runId = runOf(note('HardenTE', null, item.Id, 'Decision', 'big 0').auditRecordId);
out('big.run', runId);
out('big.item', item.Id);
`;
const VOLUME_ADD = `
for (Integer i = 0; i < {{K}}; i++) { note('HardenTE', '{{RUN}}', '{{ITEM}}', 'Decision', 'big batch {{B}} entry ' + i); }
`;
const VOLUME_END = `
Id runId = '{{RUN}}';
check('volume.bigRunCount', entries(runId) == {{TOTAL}}, entries(runId));
Long t0 = Limits.getCpuTime();
AgentAuditRecorder.sealSession(runId);
check('volume.bigRunSeal', [SELECT Merkle_Root__c FROM Agent_Audit_Session__c WHERE Id = :runId].Merkle_Root__c != null, 'CPU ms ' + (Limits.getCpuTime() - t0));
Long t1 = Limits.getCpuTime();
AgentAuditRecorder.VerifySessionResult v = AgentAuditRecorder.verifySession(runId);
check('volume.bigRunVerify', v.valid == true, 'CPU ms ' + (Limits.getCpuTime() - t1) + ', heap ' + Limits.getHeapSize());
Long t2 = Limits.getCpuTime();
AgentLedgerEvidence.ExportedRun ex = AgentLedgerEvidence.exportRun(runId);
check('volume.bigRunExport', ex.json.length() > 0, 'CPU ms ' + (Limits.getCpuTime() - t2) + ', ' + ex.json.length() + ' chars');
out('run.big', [SELECT Name FROM Agent_Audit_Session__c WHERE Id = :runId].Name);
`;

// Concurrent writers to one run: the chain must not fork.
const CONC_START = `
Hardening_Item__c item = new Hardening_Item__c(Name = 'Concurrent item');
insert item;
out('conc.run', runOf(note('HardenTE', null, item.Id, 'Decision', 'conc start').auditRecordId));
out('conc.item', item.Id);
`;
const CONC_ADD = `
for (Integer i = 0; i < {{K}}; i++) { note('HardenTE', '{{RUN}}', '{{ITEM}}', 'Decision', 'writer {{W}} entry ' + i); }
`;
const CONC_END = `
Id runId = '{{RUN}}';
List<Agent_Audit_Record__c> es = [SELECT Sequence_Number__c, Previous_Hash__c, Record_Hash__c FROM Agent_Audit_Record__c WHERE Audit_Session__c = :runId ORDER BY Sequence_Number__c];
Set<Decimal> seqs = new Set<Decimal>();
Set<String> prevs = new Set<String>();
for (Agent_Audit_Record__c e : es) { seqs.add(e.Sequence_Number__c); prevs.add(e.Previous_Hash__c); }
check('concurrency.count', es.size() == {{TOTAL}}, es.size());
check('concurrency.uniqueSequence', seqs.size() == es.size() && es[es.size() - 1].Sequence_Number__c == es.size() - 1, seqs.size());
check('concurrency.noFork', prevs.size() == es.size(), 'distinct previous hashes ' + prevs.size());
AgentAuditRecorder.sealSession(runId);
check('concurrency.verify', AgentAuditRecorder.verifySession(runId).valid == true, 'verified');
out('run.conc', [SELECT Name FROM Agent_Audit_Session__c WHERE Id = :runId].Name);
`;



// ── Run ──

const t0 = Date.now();
const ONLY = process.env.ONLY ? process.env.ONLY.split(',') : null;
const want = (s) => !ONLY || ONLY.includes(s);
console.log('Objects...');
if (want('objects')) await Promise.all(OBJECTS.map(([OBJ, CREATE, UPDATE, FIELD]) => apex('objects', ADMIN, FLOW, { OBJ, CREATE, UPDATE, FIELD })));
if (want('failures')) {
console.log('Failures and modes...');
await apex('failures', ADMIN, FAILURES);
await apex('modes', ADMIN, MODES);
}
if (want('volume')) {
console.log('Volume...');
await apex('volume', ADMIN, VOLUME_ONE_TX, { N: 25 });
await apex('volume', ADMIN, VOLUME_ONE_TX, { N: 45 });
await apex('volume', ADMIN, VOLUME_START);
const BATCHES = 10, K = 20;
for (let b = 0; b < BATCHES; b++) await apex('volume', ADMIN, VOLUME_ADD, { RUN: outputs['big.run'], ITEM: outputs['big.item'], K, B: b });
await apex('volume', ADMIN, VOLUME_END, { RUN: outputs['big.run'], TOTAL: 1 + BATCHES * K });
}
if (want('concurrency')) {
console.log('Concurrency...');
await apex('concurrency', ADMIN, CONC_START);
const WRITERS = 6, PER = 5;
await Promise.all(Array.from({ length: WRITERS }, (_, w) =>
  apex('concurrency', ADMIN, CONC_ADD, { RUN: outputs['conc.run'], ITEM: outputs['conc.item'], K: PER, W: w })));
await apex('concurrency', ADMIN, CONC_END, { RUN: outputs['conc.run'], TOTAL: 1 + WRITERS * PER });
}
if (want('access')) {
// Standard and Platform users cannot run anonymous Apex: these scenarios are
// Apex tests that impersonate the viewer and the agent user (System.runAs).
async function impersonating(scenario, testClass) {
  let test;
  try {
    const { stdout } = await execFileP('sf', ['apex', 'run', 'test', '-n', testClass, '-o', ADMIN, '-w', '10', '--json'],
      { shell: process.platform === 'win32', maxBuffer: 64 << 20 });
    test = JSON.parse(stdout);
  } catch (e) {
    test = e.stdout ? JSON.parse(e.stdout) : { result: { tests: [] } };
  }
  const tests = test.result?.tests ?? [];
  for (const t of tests) results.push({ scenario, pass: t.Outcome === 'Pass', name: t.MethodName, detail: t.Message || 'passed' });
  if (!tests.length) results.push({ scenario, pass: false, name: 'script', detail: test.message || 'test did not run' });
}
console.log('Access and agent user...');
if (want('access')) await impersonating('access', 'HardeningViewerTest');
if (want('agent')) await impersonating('agent', 'HardeningAgentUserTest');

}
// ── Report ──

const runNames = Object.entries(outputs).filter(([k]) => k.startsWith('run.')).map(([, v]) => v);
fs.writeFileSync(path.join(os.tmpdir(), 'al-hardening-runs.txt'), runNames.join(' '));
let scenario = '';
for (const r of results) {
  if (r.scenario !== scenario) { scenario = r.scenario; console.log(`\n${scenario}`); }
  console.log(`  ${r.pass ? 'PASS' : 'FAIL'} ${r.name}  ${r.detail.slice(0, 220)}`);
}
const failed = results.filter((r) => !r.pass).length;
console.log(`\n${results.length - failed} passed, ${failed} failed, in ${Math.round((Date.now() - t0) / 1000)}s`);
console.log(`Runs to export-check: ${runNames.join(' ')}`);
process.exit(failed ? 1 : 0);
