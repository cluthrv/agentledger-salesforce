// Generates the AgentLedger permission sets from the objects, fields and classes in force-app,
// so they always cover every field and class.
//
//   node scripts/make-permission-sets.mjs
//
// AgentLedger Admin           admins: everything visible (View All), read-only fields, all classes, tabs
// AgentLedger User            people who work on records and talk to employee agents:
//                             read access, the record-page component, and the agent actions
// AgentLedger Agent           the user of a service agent: the agent actions only
// AgentLedger Tamper Testing  testing only: may edit entries to see tamper detection work
import fs from 'node:fs';
import path from 'node:path';
import { fileURLToPath } from 'node:url';

const root = path.join(path.dirname(fileURLToPath(import.meta.url)), '..', 'force-app', 'main', 'default');
const OBJECTS = ['Agent_Audit_Session__c', 'Agent_Audit_Record__c', 'Agent_Instructions_Snapshot__c'];
const ACTIONS = ['StartAgentLedgerSessionAction', 'RecordAgentActionAction', 'SealAgentLedgerSessionAction',
  'VerifyAgentLedgerSessionAction', 'GetRecordAgentLedgerAction', 'UpdateRecordAgentLedgerAction',
  'CreateRecordAgentLedgerAction'];
const TAMPER_FIELDS = ['Agent_Audit_Record__c.Reasoning__c', 'Agent_Audit_Record__c.Input_Context__c',
  'Agent_Audit_Record__c.Output_Result__c', 'Agent_Audit_Record__c.Summary__c', 'Agent_Audit_Record__c.Field_Changes__c',
  'Agent_Audit_Record__c.Previous_Hash__c']; // Record_Hash__c is required, so it is editable without a field permission

// Fields that may appear in a permission set: not required, not master-detail.
function fieldsOf(object) {
  const dir = path.join(root, 'objects', object, 'fields');
  return fs.readdirSync(dir).filter((f) => f.endsWith('.field-meta.xml')).sort().flatMap((f) => {
    const xml = fs.readFileSync(path.join(dir, f), 'utf8');
    if (/<required>true<\/required>/.test(xml) || /<type>MasterDetail<\/type>/.test(xml)) return [];
    return [`${object}.${f.replace('.field-meta.xml', '')}`];
  });
}
const classes = fs.readdirSync(path.join(root, 'classes'))
  .filter((f) => f.endsWith('.cls') && !/Test\.cls$/.test(f)).map((f) => f.replace('.cls', '')).sort();

const x = {
  cls: (c) => `    <classAccesses>\n        <apexClass>${c}</apexClass>\n        <enabled>true</enabled>\n    </classAccesses>\n`,
  fld: (f, edit) => `    <fieldPermissions>\n        <editable>${edit}</editable>\n        <field>${f}</field>\n        <readable>true</readable>\n    </fieldPermissions>\n`,
  obj: (o, { edit = false, viewAll = false } = {}) => `    <objectPermissions>\n        <allowCreate>false</allowCreate>\n        <allowDelete>false</allowDelete>\n` +
    `        <allowEdit>${edit}</allowEdit>\n        <allowRead>true</allowRead>\n        <modifyAllRecords>false</modifyAllRecords>\n` +
    `        <object>${o}</object>\n        <viewAllRecords>${viewAll}</viewAllRecords>\n    </objectPermissions>\n`,
  app: (a) => `    <applicationVisibilities>
        <application>${a}</application>
        <visible>true</visible>
    </applicationVisibilities>
`,
  tab: (t) => `    <tabSettings>\n        <tab>${t}</tab>\n        <visibility>Visible</visibility>\n    </tabSettings>\n`,
};
function permissionSet(name, label, description, body) {
  const xml = '<?xml version="1.0" encoding="UTF-8"?>\n<PermissionSet xmlns="http://soap.sforce.com/2006/04/metadata">\n' +
    body + `    <description>${description}</description>\n    <hasActivationRequired>false</hasActivationRequired>\n    <label>${label}</label>\n</PermissionSet>\n`;
  fs.writeFileSync(path.join(root, 'permissionsets', `${name}.permissionset-meta.xml`), xml);
  console.log('wrote', name);
}
const allFields = OBJECTS.flatMap(fieldsOf);

permissionSet('AgentLedger_Admin', 'AgentLedger Admin',
  'Sees every AgentLedger run, entry and instructions snapshot (read-only; the ledger is append-only), runs all AgentLedger classes, and has the AgentLedger tabs.',
  x.app('AgentLedger') + classes.map(x.cls).join('') + allFields.map((f) => x.fld(f, false)).join('') +
  OBJECTS.map((o) => x.obj(o, { viewAll: true })).join('') +
  ['AgentLedger_Activity', 'AgentLedger_Setup', 'Agent_Audit_Record__c', 'Agent_Audit_Session__c'].map(x.tab).join(''));

permissionSet('AgentLedger_User', 'AgentLedger User',
  'For people who work on records and use employee agents: read the activity log of records they can see, verify runs, and run the AgentLedger agent actions.',
  x.app('AgentLedger') +
  ['RecordAuditTrailController', 'AgentLedgerTimelineController', 'AgentLedgerActivityController', 'AgentLedgerEvidence', ...ACTIONS].sort().map(x.cls).join('') +
  allFields.map((f) => x.fld(f, false)).join('') + OBJECTS.map((o) => x.obj(o)).join('') + x.tab('AgentLedger_Activity'));

permissionSet('AgentLedger_Agent', 'AgentLedger Agent',
  'For the user a service agent runs as: the AgentLedger agent actions. The ledger is written by AgentLedger itself, so no object access is needed.',
  [...ACTIONS].sort().map(x.cls).join(''));

const tamperBody =
  '    <customPermissions>\n        <enabled>true</enabled>\n        <name>AgentLedger_Allow_Entry_Edits</name>\n    </customPermissions>\n' +
  TAMPER_FIELDS.map((f) => x.fld(f, true)).join('') + x.obj('Agent_Audit_Record__c', { edit: true }) + x.obj('Agent_Audit_Session__c');
permissionSet('AgentLedger_Tamper_Testing', 'AgentLedger Tamper Testing',
  'For testing only: lets the user edit AgentLedger entries to see tamper detection work. Verification still detects every edit. Do not assign in production.',
  tamperBody);
