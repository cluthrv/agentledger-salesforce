// Prepares a clean org for the hardening suite the way a customer would get
// there: install an earlier package version, use it, upgrade to the new one,
// and check settings and runs survived. Then deploys the test-only metadata
// and creates the test users.
//
//   node hardening/setup.mjs <dev-hub> <alias> <old 04t> <new 04t>
import fs from 'node:fs';
import os from 'node:os';
import path from 'node:path';
import { execFileSync } from 'node:child_process';
import { fileURLToPath } from 'node:url';

const [HUB, ALIAS, OLD, NEW] = process.argv.slice(2);
if (!NEW) {
  console.error('usage: node hardening/setup.mjs <dev-hub> <alias> <old 04t> <new 04t>');
  process.exit(2);
}
const repo = path.resolve(path.dirname(fileURLToPath(import.meta.url)), '..');
const sf = (args) => {
  const out = execFileSync('sf', [...args, '--json'], { cwd: repo, encoding: 'utf8', shell: process.platform === 'win32', maxBuffer: 64 << 20 });
  const json = JSON.parse(out);
  if (json.status !== 0) throw new Error(json.message);
  return json.result;
};
const apex = (code) => {
  const file = path.join(os.tmpdir(), `al-setup-${process.pid}.apex`);
  fs.writeFileSync(file, code);
  try {
    const r = sf(['apex', 'run', '-f', file, '-o', ALIAS]);
    if (!r.success) throw new Error(r.compileProblem || r.exceptionMessage);
    return [...r.logs.matchAll(/\|DEBUG\|OUT (\S+) (.*)/g)].reduce((o, m) => ({ ...o, [m[1]]: m[2].trim() }), {});
  } finally {
    fs.unlinkSync(file);
  }
};
const step = (s) => console.log(`\n== ${s}`);
const sleep = (ms) => new Promise((r) => setTimeout(r, ms));
const problems = [];
const expect = (ok, what) => { console.log(`  ${ok ? 'PASS' : 'FAIL'} ${what}`); if (!ok) problems.push(what); };

step('Clean org');
const org = sf(['org', 'create', 'scratch', '-f', 'config/build-def.json', '-a', ALIAS, '-v', HUB, '-y', '3', '-w', '20']);
console.log(`  ${org.username}`);

step(`Install the earlier version ${OLD}`);
sf(['package', 'install', '-p', OLD, '-o', ALIAS, '-w', '30', '-r']);
sf(['org', 'assign', 'permset', '-n', 'AgentLedger_Admin', '-n', 'AgentLedger_User', '-o', ALIAS]);

step('Use it: set the org default to Tamper-Evident, record and close a run');
apex(`
AgentLedgerSetupController.SettingView v = new AgentLedgerSetupController.SettingView();
v.developerName = 'Org_Default'; v.enabled = true; v.mode = 'Tamper_Evident'; v.autoCloseMinutes = 45; v.storeFieldValues = true;
AgentLedgerSetupController.saveSetting(v);`);
for (let i = 0; i < 30; i++) {
  const o = apex(`System.debug('OUT mode ' + AgentLedgerSettings.orgDefault().mode);`);
  if (o.mode === 'Tamper_Evident') break;
  await sleep(5000);
}
const before = apex(`
Case c = new Case(Subject = 'Before upgrade', Status = 'New', Origin = 'Web');
insert c;
UpdateRecordAgentLedgerAction.Request r = new UpdateRecordAgentLedgerAction.Request();
r.agentId = 'UpgradeAgent'; r.recordId = c.Id; r.fieldValues = '{"Status": "Working"}'; r.reasoning = 'before upgrade';
Id runId = UpdateRecordAgentLedgerAction.execute(new List<UpdateRecordAgentLedgerAction.Request>{ r })[0].sessionId;
AgentAuditRecorder.sealSession(runId);
System.debug('OUT run ' + runId);
System.debug('OUT mode ' + [SELECT Mode__c FROM Agent_Audit_Session__c WHERE Id = :runId].Mode__c);
System.debug('OUT valid ' + AgentAuditRecorder.verifySession(runId).valid);`);
expect(before.mode === 'Tamper_Evident' && before.valid === 'true', `run before upgrade is Tamper-Evident and verifies (${before.mode}, ${before.valid})`);

step(`Upgrade to ${NEW}`);
sf(['package', 'install', '-p', NEW, '-o', ALIAS, '-w', '30', '-r', '-t', 'Mixed']);
const after = apex(`
AgentLedgerSettings.Resolved d = AgentLedgerSettings.orgDefault();
System.debug('OUT mode ' + d.mode);
System.debug('OUT minutes ' + d.autoCloseMinutes);
System.debug('OUT valid ' + AgentAuditRecorder.verifySession('${before.run}').valid);
System.debug('OUT exported ' + (AgentLedgerEvidence.exportRun('${before.run}').json.length() > 0));`);
expect(after.mode === 'Tamper_Evident', `org default mode kept after upgrade (now ${after.mode})`);
expect(after.minutes === '45', `auto-close minutes kept after upgrade (now ${after.minutes})`);
expect(after.valid === 'true', 'run from before the upgrade still verifies');
expect(after.exported === 'true', 'run from before the upgrade exports');

step('Test-only metadata');
sf(['project', 'deploy', 'start', '-d', 'hardening/main', '-o', ALIAS, '-w', '20']);
sf(['org', 'assign', 'permset', '-n', 'Hardening_Full', '-o', ALIAS]);

step('Test users');
// Developer Edition orgs have two full user licences: the admin and the viewer.
const user = (name, permsets, profileName = 'Standard User') => {
  const def = path.join(os.tmpdir(), `al-user-${name}.json`);
  fs.writeFileSync(def, JSON.stringify({ profileName, permsets, lastName: `Hardening ${name}` }));
  const r = sf(['org', 'create', 'user', '-o', ALIAS, '-f', def, '-a', `${ALIAS}-${name}`]);
  fs.unlinkSync(def);
  console.log(`  ${name}: ${r.fields?.username ?? r.username}`);
  return r.fields?.username ?? r.username;
};
const viewer = user('viewer', ['AgentLedger_User', 'Hardening_Viewer']);
const agent = user('agent', ['AgentLedger_Agent', 'Hardening_Full'], 'Standard Platform User');

console.log(`\nNext: node hardening/run.mjs ${ALIAS} ${viewer} ${agent}`);
if (problems.length) {
  console.log(`\n${problems.length} upgrade problem(s):\n  ${problems.join('\n  ')}`);
  process.exit(1);
}
