// Validates and deploys AgentLedger to an org, running every AgentLedger test.
// The hourly auto-close job is paused for the deploy (Salesforce does not
// deploy Apex while a scheduled job is pending) and resumed afterwards.
//
//   node scripts/deploy.mjs <org-alias>              validate, then deploy
//   node scripts/deploy.mjs <org-alias> --validate   validate only
import { execSync } from 'node:child_process';
import fs from 'node:fs';
import os from 'node:os';
import path from 'node:path';
import { fileURLToPath } from 'node:url';

const [org, flag] = process.argv.slice(2);
if (!org) {
  console.error('Usage: node scripts/deploy.mjs <org-alias> [--validate]');
  process.exit(2);
}
const validateOnly = flag === '--validate';
const root = path.join(path.dirname(fileURLToPath(import.meta.url)), '..');
const tmp = fs.mkdtempSync(path.join(os.tmpdir(), 'agentledger-deploy-'));

function sf(args) {
  try {
    return execSync(`sf ${args}`, { cwd: root, encoding: 'utf8', stdio: ['ignore', 'pipe', 'ignore'], maxBuffer: 64 * 1024 * 1024 });
  } catch (e) {
    return e.stdout || '';
  }
}
function apex(code) {
  const file = path.join(tmp, 'snippet.apex');
  fs.writeFileSync(file, code);
  const out = sf(`apex run --target-org ${org} --file "${file}"`);
  return out.split('\n').filter((l) => l.includes('USER_DEBUG')).map((l) => l.split('|DEBUG|').pop().trim());
}

const tests = fs.readdirSync(path.join(root, 'force-app/main/default/classes'))
  .filter((f) => f.endsWith('Test.cls')).map((f) => `--tests ${f.replace('.cls', '')}`).join(' ');

console.log('Pausing auto-close:', apex(
  "Integer n = 0; for (CronTrigger ct : [SELECT Id FROM CronTrigger WHERE CronJobDetail.Name = 'AgentLedger auto-close']) { System.abortJob(ct.Id); n++; } System.debug('paused ' + n);").join(' '));
let failed = false;
try {
  console.log('Validating with all AgentLedger tests...');
  const result = JSON.parse(sf(`project deploy validate --source-dir force-app --target-org ${org} --test-level RunSpecifiedTests ${tests} ` +
    `--coverage-formatters text-summary --results-dir "${tmp}" --wait 30 --json`) || '{}');
  if (!result.result || !result.result.success) {
    console.error(result.message || 'Validation failed');
    failed = true;
  } else {
    const t = result.result.details.runTestResult;
    console.log(`Tests: ${t.numTestsRun} run, ${t.numFailures} failed`);
    const cov = path.join(tmp, 'coverage', 'text-summary.txt');
    if (fs.existsSync(cov)) console.log(fs.readFileSync(cov, 'utf8').split('\n').find((l) => l.startsWith('Lines')));
    if (!validateOnly) {
      const d = JSON.parse(sf(`project deploy quick --job-id ${result.result.id} --target-org ${org} --wait 30 --json`) || '{}');
      console.log('Deploy:', d.result ? d.result.status : d.message);
      failed = !d.result || d.result.status !== 'Succeeded';
    }
  }
} finally {
  console.log('Resuming auto-close:', apex(
    "if ([SELECT COUNT() FROM CronTrigger WHERE CronJobDetail.Name = 'AgentLedger auto-close'] == 0) { System.debug('resumed ' + AgentLedgerAutoClose.scheduleHourly()); } else { System.debug('already on'); }").join(' '));
}
process.exit(failed ? 1 : 0);
