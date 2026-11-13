// Writes the test-only metadata the hardening suite deploys next to the
// package in a clean org (hardening/main/default). Not part of the package.
//
//   node hardening/make-metadata.mjs
import fs from 'node:fs';
import path from 'node:path';
import { fileURLToPath } from 'node:url';

const base = path.join(path.dirname(fileURLToPath(import.meta.url)), 'main', 'default');
const put = (rel, text) => {
  const file = path.join(base, rel);
  fs.mkdirSync(path.dirname(file), { recursive: true });
  fs.writeFileSync(file, text.trimStart());
};
const NS = 'xmlns="http://soap.sforce.com/2006/04/metadata"';

// A private object, so record access can be tested, with a field one user may not read.
put('objects/Hardening_Item__c/Hardening_Item__c.object-meta.xml', `
<?xml version="1.0" encoding="UTF-8"?>
<CustomObject ${NS}>
    <deploymentStatus>Deployed</deploymentStatus>
    <label>Hardening Item</label>
    <pluralLabel>Hardening Items</pluralLabel>
    <nameField><label>Item Name</label><type>Text</type></nameField>
    <sharingModel>Private</sharingModel>
    <externalSharingModel>Private</externalSharingModel>
    <enableHistory>true</enableHistory>
</CustomObject>
`);
const field = (name, xml) => put(`objects/Hardening_Item__c/fields/${name}.field-meta.xml`, `
<?xml version="1.0" encoding="UTF-8"?>
<CustomField ${NS}>
    <fullName>${name}</fullName>
${xml}
</CustomField>
`);
field('Amount__c', '    <label>Amount</label><type>Number</type><precision>16</precision><scale>2</scale><trackHistory>true</trackHistory>');
field('Status__c', '    <label>Status</label><type>Text</type><length>40</length><trackHistory>true</trackHistory>');
field('Secret__c', '    <label>Secret</label><type>Text</type><length>255</length><trackHistory>true</trackHistory>');

put('objects/Hardening_Item__c/validationRules/No_Negative_Amount.validationRule-meta.xml', `
<?xml version="1.0" encoding="UTF-8"?>
<ValidationRule ${NS}>
    <fullName>No_Negative_Amount</fullName>
    <active>true</active>
    <errorConditionFormula>Amount__c &lt; 0</errorConditionFormula>
    <errorMessage>Amount cannot be negative.</errorMessage>
</ValidationRule>
`);

const objPerm = (read, edit) => `
    <objectPermissions>
        <allowCreate>${edit}</allowCreate><allowDelete>false</allowDelete><allowEdit>${edit}</allowEdit>
        <allowRead>${read}</allowRead><modifyAllRecords>false</modifyAllRecords>
        <object>Hardening_Item__c</object><viewAllRecords>false</viewAllRecords>
    </objectPermissions>`;
const fieldPerm = (f, read, edit) => `
    <fieldPermissions><editable>${edit}</editable><field>Hardening_Item__c.${f}</field><readable>${read}</readable></fieldPermissions>`;

// Full access, for the agent user.
put('permissionsets/Hardening_Full.permissionset-meta.xml', `
<?xml version="1.0" encoding="UTF-8"?>
<PermissionSet ${NS}>
    <label>Hardening Full</label>${objPerm(true, true)}${fieldPerm('Amount__c', true, true)}${fieldPerm('Status__c', true, true)}${fieldPerm('Secret__c', true, true)}
</PermissionSet>
`);
// Read access without the Secret field, for the viewer.
put('permissionsets/Hardening_Viewer.permissionset-meta.xml', `
<?xml version="1.0" encoding="UTF-8"?>
<PermissionSet ${NS}>
    <label>Hardening Viewer</label>${objPerm(true, false)}${fieldPerm('Amount__c', true, false)}${fieldPerm('Status__c', true, false)}
</PermissionSet>
`);

// Makes writing a log entry fail on request, to test what happens to the change.
put('triggers/HardeningLogFailure.trigger', `
trigger HardeningLogFailure on Agent_Audit_Record__c (before insert) {
    for (Agent_Audit_Record__c e : Trigger.new) {
        if (e.Reasoning__c != null && e.Reasoning__c.contains('FORCE_LOG_FAILURE')) {
            e.addError('Hardening: forced log failure');
        }
    }
}
`);
put('triggers/HardeningLogFailure.trigger-meta.xml', `
<?xml version="1.0" encoding="UTF-8"?>
<ApexTrigger ${NS}>
    <apiVersion>65.0</apiVersion>
    <status>Active</status>
</ApexTrigger>
`);

// Watches the test object for changes made outside AgentLedger: the documented
// way to add an object to the change detector.
put('triggers/HardeningItemDetector.trigger', `
trigger HardeningItemDetector on Hardening_Item__c (after insert, after update, after delete) {
    AgentLedgerChangeDetector.handle();
}
`);
put('triggers/HardeningItemDetector.trigger-meta.xml', `
<?xml version="1.0" encoding="UTF-8"?>
<ApexTrigger ${NS}>
    <apiVersion>65.0</apiVersion>
    <status>Active</status>
</ApexTrigger>
`);

// One agent setting per mode under test.
const setting = (dev, label, values) => put(`customMetadata/AgentLedger_Setting.${dev}.md-meta.xml`, `
<?xml version="1.0" encoding="UTF-8"?>
<CustomMetadata xmlns="http://soap.sforce.com/2006/04/metadata" xmlns:xsi="http://www.w3.org/2001/XMLSchema-instance" xmlns:xsd="http://www.w3.org/2001/XMLSchema">
    <label>${label}</label>
    <protected>false</protected>
${Object.entries(values).map(([f, v]) => `    <values><field>${f}</field><value xsi:type="xsd:${typeof v === 'boolean' ? 'boolean' : 'string'}">${v}</value></values>`).join('\n')}
</CustomMetadata>
`);
setting('Harden_TE', 'Harden TE', { Agent_Api_Name__c: 'HardenTE', Enabled__c: true, Mode__c: 'Tamper_Evident', Policy_Reference__c: 'Hardening Policy v1' });
setting('Harden_AL_Continue', 'Harden AL Continue', { Agent_Api_Name__c: 'HardenALC', Enabled__c: true, Mode__c: 'Activity_Log', On_Log_Failure__c: 'Continue' });
setting('Harden_Off', 'Harden Off', { Agent_Api_Name__c: 'HardenOff', Enabled__c: false });

console.log('hardening metadata written to', base);
