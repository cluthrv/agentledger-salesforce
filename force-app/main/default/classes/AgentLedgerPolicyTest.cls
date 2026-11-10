/**
 * AgentLedgerPolicyTest
 *
 * Phase 1 step 5: what the agent acted under (version, instructions, policy)
 * is captured by code, kept, and covered by entry hashes; runs are private and
 * visible to whoever can read the related record; only AgentLedger creates
 * ledger records.
 */
@isTest
private class AgentLedgerPolicyTest {

    private static final String CASE_ID = '500000000000001';
    private static final String AGENT = 'CaseEscalationAgent';

    private static AgentLedgerPolicy.AgentDefinition definition(String version, String instructions) {
        AgentLedgerPolicy.AgentDefinition d = new AgentLedgerPolicy.AgentDefinition();
        d.agentName = AGENT;
        d.version = version;
        d.content = AgentLedgerCanonical.serialize(new Map<String, Object>{
            'agent' => AGENT, 'version' => version,
            'subagents' => new List<Object>{ new Map<String, Object>{ 'name' => 'CaseEscalation', 'instructions' => instructions } }
        });
        return d;
    }

    private static void useAgent(String version, String instructions, String policyReference, String policyText) {
        AgentLedgerPolicy.definitionsForTest = new Map<String, AgentLedgerPolicy.AgentDefinition>{ AGENT => definition(version, instructions) };
        AgentLedgerSettings.recordsForTest = (List<AgentLedger_Setting__mdt>) System.JSON.deserialize(
            '[{"DeveloperName":"Org_Default","Enabled__c":true,"Mode__c":"Tamper_Evident"},' +
            '{"DeveloperName":"Case_Agent","Agent_Api_Name__c":"case-escalation-agent","Enabled__c":true,' +
            '"Agentforce_Agent__c":"' + AGENT + '"' +
            (policyReference == null ? '' : ',"Policy_Reference__c":"' + policyReference + '"') +
            (policyText == null ? '' : ',"Policy_Text__c":"' + policyText + '"') + '}]',
            List<AgentLedger_Setting__mdt>.class);
    }

    @isTest
    static void runsAndEntriesRecordWhatTheAgentActedUnder() {
        useAgent('CaseEscalationAgent v3 (Active)', 'Escalate when Priority is High.', 'Escalation Policy v3', 'Escalate High priority cases.');
        Id runId = AgentAuditRecorder.startSession('case-escalation-agent', CASE_ID, 'agentforce');
        AgentAuditRecorder.recordAction(runId, 'case-escalation-agent', 'Decision', 'High, New', 'Escalate', 'Meets the policy');

        Agent_Audit_Session__c run = [SELECT Agent_Version__c, Instructions_Hash__c, Policy_Reference__c, Policy_Hash__c
                                      FROM Agent_Audit_Session__c WHERE Id = :runId];
        System.assertEquals('CaseEscalationAgent v3 (Active)', run.Agent_Version__c);
        System.assertEquals(64, run.Instructions_Hash__c.length());
        System.assertEquals('Escalation Policy v3', run.Policy_Reference__c);
        System.assertEquals(HashChainService.sha256(AgentLedgerPolicy.POLICY_TAG + 'Escalate High priority cases.'), run.Policy_Hash__c);

        Agent_Instructions_Snapshot__c snap = [SELECT Agent_Name__c, Agent_Version__c, Content__c
                                               FROM Agent_Instructions_Snapshot__c WHERE Instructions_Hash__c = :run.Instructions_Hash__c];
        System.assert(snap.Content__c.contains('Escalate when Priority is High.'), 'the instruction text is kept');
        System.assertEquals(run.Instructions_Hash__c,
            HashChainService.sha256(AgentLedgerPolicy.INSTRUCTIONS_TAG + snap.Content__c), 'the snapshot reproduces the hash');

        Agent_Audit_Record__c entry = [SELECT Agent_Version__c, Instructions_Hash__c, Policy_Reference__c, Policy_Hash__c
                                       FROM Agent_Audit_Record__c WHERE Audit_Session__c = :runId];
        System.assertEquals(run.Agent_Version__c, entry.Agent_Version__c);
        System.assertEquals(run.Instructions_Hash__c, entry.Instructions_Hash__c);
        System.assertEquals(run.Policy_Reference__c, entry.Policy_Reference__c);
        System.assertEquals(run.Policy_Hash__c, entry.Policy_Hash__c);
    }

    @isTest
    static void oneSnapshotPerVersionAndANewOneWhenInstructionsChange() {
        useAgent('CaseEscalationAgent v3 (Active)', 'Escalate when Priority is High.', null, null);
        Id first = AgentAuditRecorder.startSession('case-escalation-agent', CASE_ID, 'agentforce');
        Id second = AgentAuditRecorder.startSession('case-escalation-agent', CASE_ID, 'agentforce');
        System.assertEquals(1, [SELECT COUNT() FROM Agent_Instructions_Snapshot__c]);

        useAgent('CaseEscalationAgent v3 (Active)', 'Escalate when Priority is High or Critical.', null, null);
        Id third = AgentAuditRecorder.startSession('case-escalation-agent', CASE_ID, 'agentforce');
        System.assertEquals(2, [SELECT COUNT() FROM Agent_Instructions_Snapshot__c], 'an edit to the instructions is a new version');
        System.assertNotEquals(
            [SELECT Instructions_Hash__c FROM Agent_Audit_Session__c WHERE Id = :first].Instructions_Hash__c,
            [SELECT Instructions_Hash__c FROM Agent_Audit_Session__c WHERE Id = :third].Instructions_Hash__c);
    }

    @isTest
    static void theEntryHashCoversThePolicyFields() {
        useAgent('CaseEscalationAgent v3 (Active)', 'Escalate when Priority is High.', 'Escalation Policy v3', null);
        Id runId = AgentAuditRecorder.startSession('case-escalation-agent', CASE_ID, 'agentforce');
        Agent_Audit_Record__c rec = AgentAuditRecorder.recordAction(runId, 'case-escalation-agent', 'Decision', 'in', 'Escalate', 'why');
        AgentAuditRecorder.sealSession(runId);
        System.assert(AgentAuditRecorder.verifySession(runId).valid);

        AgentLedgerGuard.allowManualEditsForTest = true; // claim a different policy afterwards
        update new Agent_Audit_Record__c(Id = rec.Id, Policy_Reference__c = 'Escalation Policy v4');
        AgentLedgerGuard.allowManualEditsForTest = false;
        System.assert(!AgentAuditRecorder.verifySession(runId).valid, 'citing a different policy afterwards is detected');
    }

    @isTest
    static void aStepCanCiteTheRuleItApplied() {
        useAgent('CaseEscalationAgent v3 (Active)', 'Escalate when Priority is High.', 'Escalation Policy v3', null);
        RecordAgentActionAction.Request req = new RecordAgentActionAction.Request();
        req.agentId = 'case-escalation-agent';
        req.actionType = 'Decision';
        req.reasoning = 'High priority, not yet escalated.';
        req.relatedRecordId = CASE_ID;
        req.policyReference = 'Escalation Policy v3, rule 2';
        RecordAgentActionAction.Result res = RecordAgentActionAction.execute(new List<RecordAgentActionAction.Request>{ req })[0];
        System.assert(res.success, res.errorMessage);
        System.assertEquals('Escalation Policy v3, rule 2', [SELECT Policy_Reference__c FROM Agent_Audit_Record__c WHERE Id = :res.auditRecordId].Policy_Reference__c);
    }

    @isTest
    static void anUnknownAgentStillRecordsWithoutAVersion() {
        AgentLedgerPolicy.definitionsForTest = new Map<String, AgentLedgerPolicy.AgentDefinition>();
        AgentLedgerSettings.recordsForTest = new List<AgentLedger_Setting__mdt>();
        Id runId = AgentAuditRecorder.startSession('some-agent', CASE_ID, 'agentforce');
        Agent_Audit_Session__c run = [SELECT Agent_Version__c, Instructions_Hash__c FROM Agent_Audit_Session__c WHERE Id = :runId];
        System.assertEquals(null, run.Agent_Version__c);
        System.assertEquals(null, run.Instructions_Hash__c);
    }

    @isTest
    static void readingTheOrgsAgentDefinitionsNeverBlocksARun() {
        // No test definitions: the org's own definitions are read, whatever exists.
        AgentLedgerSettings.recordsForTest = new List<AgentLedger_Setting__mdt>();
        Id runId = AgentAuditRecorder.startSession(AGENT, CASE_ID, 'agentforce');
        System.assertNotEquals(null, runId);
    }

    @isTest
    static void theInstructionsDocumentIsCanonical() {
        Map<String, Object> sub = AgentLedgerPolicy.subagent('CaseEscalation', 'Case Escalation', 'Reviews cases', 'Cases only',
            new List<Object>{ new Map<String, Object>{ 'name' => 'instruction_1', 'text' => 'Escalate when Priority is High.' } });
        AgentLedgerPolicy.AgentDefinition d = AgentLedgerPolicy.buildDefinition(AGENT, AGENT + ' v1 (Active)',
            new List<Map<String, Object>>{ sub, AgentLedgerPolicy.subagent('GeneralFAQ', 'General FAQ', null, null, null) });
        System.assert(d.content.startsWith('{"agent":"CaseEscalationAgent","subagents":[{"description":"Reviews cases"'), d.content);
        System.assert(d.content.contains('"scope":"Cases only"'));
        System.assert(d.content.contains('{"instructions":[],"label":"General FAQ","name":"GeneralFAQ"}'), d.content);
        System.assertEquals(d.content, AgentLedgerPolicy.buildDefinition(AGENT, AGENT + ' v1 (Active)',
            new List<Map<String, Object>>{ sub, AgentLedgerPolicy.subagent('GeneralFAQ', 'General FAQ', null, null, null) }).content,
            'the same definition always gives the same document');
    }

    @isTest
    static void snapshotsCannotBeChangedOrDeleted() {
        useAgent('CaseEscalationAgent v3 (Active)', 'Escalate when Priority is High.', null, null);
        AgentAuditRecorder.startSession('case-escalation-agent', CASE_ID, 'agentforce');
        Agent_Instructions_Snapshot__c snap = [SELECT Id FROM Agent_Instructions_Snapshot__c LIMIT 1];
        User me = [SELECT ProfileId, LocaleSidKey, LanguageLocaleKey, EmailEncodingKey, TimeZoneSidKey FROM User WHERE Id = :UserInfo.getUserId()];
        User plain = new User(ProfileId = me.ProfileId, Username = 'agentledger.snap.' + Crypto.getRandomInteger() + DateTime.now().getTime() + '@example.com',
            Email = 'agentledger.snap@example.com', LastName = 'Snap', Alias = 'alsnap', TimeZoneSidKey = me.TimeZoneSidKey,
            LocaleSidKey = me.LocaleSidKey, LanguageLocaleKey = me.LanguageLocaleKey, EmailEncodingKey = me.EmailEncodingKey);
        insert plain;
        System.runAs(plain) {
            System.assert(!Database.update(new Agent_Instructions_Snapshot__c(Id = snap.Id, Content__c = 'rewritten'), false).isSuccess());
            System.assert(!Database.delete(snap.Id, false).isSuccess());
        }
    }

    // ── Access ──

    @isTest
    static void theRecordPageShowsRunsOnlyToPeopleWhoCanReadTheRecord() {
        useAgent('CaseEscalationAgent v3 (Active)', 'x', null, null);
        Id runId = AgentAuditRecorder.startSession('case-escalation-agent', CASE_ID, 'agentforce');
        AgentAuditRecorder.recordAction(runId, 'case-escalation-agent', 'Query', 'in', 'out', 'looked');
        AgentAuditRecorder.sealSession(runId);
        Id caseId = Id.valueOf(CASE_ID);

        AgentLedgerAccess.readAccessForTest = new Map<Id, Boolean>{ caseId => true, runId => false };
        System.assertEquals(1, RecordAuditTrailController.getSessionsForRecord(CASE_ID).size());
        System.assert(AgentAuditRecorder.verifySession(runId).valid, 'reading the related record is enough to verify');

        AgentLedgerAccess.readAccessForTest = new Map<Id, Boolean>{ caseId => false, runId => false };
        System.assertEquals(0, RecordAuditTrailController.getSessionsForRecord(CASE_ID).size());
        try {
            AgentAuditRecorder.verifySession(runId);
            System.assert(false, 'no access, no verification');
        } catch (MerkleTreeService.AgentLedgerException e) {
            System.assert(e.getMessage().contains('do not have access'));
        }
        System.assertEquals(0, RecordAuditTrailController.getSessionsForRecord('not-an-id').size());
    }

    @isTest
    static void onlyAgentLedgerCreatesLedgerRecords() {
        // As a user without the testing permission, whoever runs the tests.
        User me = [SELECT ProfileId, LocaleSidKey, LanguageLocaleKey, EmailEncodingKey, TimeZoneSidKey FROM User WHERE Id = :UserInfo.getUserId()];
        User plain = new User(ProfileId = me.ProfileId, Username = 'agentledger.policy.' + Crypto.getRandomInteger() + DateTime.now().getTime() + '@example.com',
            Email = 'agentledger.policy@example.com', LastName = 'Policy', Alias = 'alpol', TimeZoneSidKey = me.TimeZoneSidKey,
            LocaleSidKey = me.LocaleSidKey, LanguageLocaleKey = me.LanguageLocaleKey, EmailEncodingKey = me.EmailEncodingKey);
        insert plain;
        Id realRun = AgentAuditRecorder.startSession('some-agent', CASE_ID, 'agentforce');
        System.runAs(plain) {
            Database.SaveResult run = Database.insert(new Agent_Audit_Session__c(
                Session_Id__c = 'forged', Agent_Id__c = 'x', Status__c = 'Active', Start_Time__c = DateTime.now()), false);
            System.assert(!run.isSuccess(), 'a run cannot be created by hand');

            Database.SaveResult entry = Database.insert(new Agent_Audit_Record__c(Audit_Session__c = realRun, Sequence_Number__c = 0,
                Agent_Id__c = 'x', Action_Type__c = 'Decision', Action_Timestamp__c = DateTime.now(), Record_Hash__c = 'forged'), false);
            System.assert(!entry.isSuccess(), 'an entry cannot be slipped into a run');

            Database.SaveResult snap = Database.insert(new Agent_Instructions_Snapshot__c(Instructions_Hash__c = 'forged'), false);
            System.assert(!snap.isSuccess(), 'a snapshot cannot be created by hand');
        }
    }
}
