// Exports runs from an org and verifies them with the published open-source
// library, outside Salesforce, then checks that a tampered copy fails.
//
//   npm install --prefix scripts/.vectors @vluthra/agent-ledger@0.2.0
//   node scripts/check-export.mjs <org-alias> <run name>...     e.g. AAS-0046
//
// Without run names it checks the 5 newest closed v2 runs.
import fs from 'node:fs';
import os from 'node:os';
import path from 'node:path';
import { execFileSync } from 'node:child_process';
import { createRequire } from 'node:module';
import { fileURLToPath } from 'node:url';

const here = path.dirname(fileURLToPath(import.meta.url));
const require = createRequire(path.join(here, '.vectors', 'package.json'));
const { verifyExportedSession } = require('@vluthra/agent-ledger');
const libVersion = require('@vluthra/agent-ledger/package.json').version;

const [org, ...names] = process.argv.slice(2);
if (!org) {
  console.error('usage: node scripts/check-export.mjs <org-alias> [run name...]');
  process.exit(2);
}

const sf = (args) => execFileSync('sf', args, { encoding: 'utf8', shell: process.platform === 'win32', maxBuffer: 64 << 20 });

const where = names.length
  ? `Name IN (${names.map((n) => `'${n.replace(/'/g, '')}'`).join(',')})`
  : `Hash_Version__c = 'v2' AND Status__c IN ('Closed','Incomplete','Sealed','Verified','Tampered') AND Record_Count__c > 0 ORDER BY CreatedDate DESC LIMIT 5`;
const apex = `for (Agent_Audit_Session__c r : [SELECT Id, Name FROM Agent_Audit_Session__c WHERE ${where}]) {
    try {
        System.debug('EXPORT ' + r.Name + ' ' + EncodingUtil.base64Encode(Blob.valueOf(AgentLedgerEvidence.exportRun(r.Id).json)));
    } catch (Exception e) {
        System.debug('EXPORTFAIL ' + r.Name + ' ' + e.getMessage());
    }
}`;
const file = path.join(os.tmpdir(), `agentledger-check-${process.pid}.apex`);
fs.writeFileSync(file, apex);
const out = JSON.parse(sf(['apex', 'run', '-f', file, '-o', org, '--json']));
fs.unlinkSync(file);
const log = out.result?.logs ?? '';
if (!out.result?.success) {
  console.error(out.result?.compileProblem || out.result?.exceptionMessage || out.message);
  process.exit(1);
}

let failures = 0;
const found = [...log.matchAll(/\|DEBUG\|(EXPORT|EXPORTFAIL) (\S+) (.*)/g)];
if (!found.length) {
  console.error('No runs found.');
  process.exit(1);
}
console.log(`Verifier: @vluthra/agent-ledger ${libVersion} (published)\n`);
for (const [, kind, name, rest] of found) {
  if (kind === 'EXPORTFAIL') {
    console.log(`${name}: not exported: ${rest}`);
    continue;
  }
  const doc = JSON.parse(Buffer.from(rest.trim(), 'base64').toString('utf8'));
  const result = verifyExportedSession(doc);
  const hidden = doc.salesforce?.hiddenFields?.length ?? 0;
  console.log(`${name}: ${result.valid ? 'VERIFIED' : 'FAILED'} (${doc.records.length} entries${hidden ? `, ${hidden} with hidden fields` : ''})`);
  for (const c of result.checks) console.log(`   ${c.passed ? 'ok  ' : 'FAIL'} ${c.name}: ${c.detail}`);

  // A tampered copy must fail: change one character of the last entry's reasoning or summary.
  const tampered = structuredClone(doc);
  const last = tampered.records[tampered.records.length - 1];
  if (last.reasoning) last.reasoning += '.';
  else last.metadata = { ...(last.metadata ?? {}), summary: 'x' };
  const t = verifyExportedSession(tampered);
  console.log(`   tampered copy: ${t.valid ? 'VERIFIED (wrong!)' : 'fails, as it should'}`);
  if ((!result.valid && !hidden) || t.valid) failures++;
}
process.exit(failures ? 1 : 0);
