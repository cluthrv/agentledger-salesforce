/**
 * AgentLedgerSettingsTest
 *
 * Phase 1 step 3: settings resolution (agent record over Org_Default over
 * built-in defaults), the mode stamped on new runs, and agents with
 * AgentLedger turned off.
 */
@isTest
private class AgentLedgerSettingsTest {

    private static final String CASE_ID = '500000000000001';

    private static void useRecords(String json) {
        AgentLedgerSettings.recordsForTest =
            (List<AgentLedger_Setting__mdt>) System.JSON.deserialize(json, List<AgentLedger_Setting__mdt>.class);
    }

    @isTest
    static void builtInDefaultsApplyWithoutRecords() {
        useRecords('[]');
        AgentLedgerSettings.Resolved r = AgentLedgerSettings.forAgent('any-agent');
        System.assert(r.enabled);
        System.assertEquals('Activity_Log', r.mode);
        System.assertEquals(30, r.autoCloseMinutes);
        System.assert(!r.isTamperEvident());
        System.assert(!r.rollBackOnLogFailure(), 'Activity Log continues when logging fails');
        System.assertEquals('None', r.anchorProvider);
    }

    @isTest
    static void orgDefaultAndAgentOverrides() {
        useRecords('[' +
            '{"DeveloperName":"Org_Default","Enabled__c":true,"Mode__c":"Tamper_Evident","Auto_Close_Minutes__c":45,' +
            '"Store_Field_Values__c":false,"Never_Store_Fields__c":"Contact.Birthdate, Account.AnnualRevenue\\nLead.Email",' +
            '"Watched_Objects__c":"Case\\nOpportunity","Retention_Days__c":365,"Anchor_Provider__c":"RFC3161","Anchor_Named_Credential__c":"AgentLedger_TSA"},' +
            '{"DeveloperName":"Case_Agent","Agent_Api_Name__c":"Case-Escalation-Agent","Enabled__c":true,"Mode__c":"Anchored","On_Log_Failure__c":"Continue"},' +
            '{"DeveloperName":"Quiet_Agent","Agent_Api_Name__c":"quiet-agent","Enabled__c":false},' +
            '{"DeveloperName":"Inherit_Agent","Agent_Api_Name__c":"inherit-agent","Enabled__c":true}' +
        ']');

        AgentLedgerSettings.Resolved org = AgentLedgerSettings.forAgent('unknown-agent');
        System.assertEquals('Tamper_Evident', org.mode);
        System.assert(org.rollBackOnLogFailure(), 'tamper modes roll back by default');
        System.assertEquals(45, org.autoCloseMinutes);
        System.assert(!org.storeFieldValues);
        System.assertEquals(new Set<String>{ 'Contact.Birthdate', 'Account.AnnualRevenue', 'Lead.Email' }, org.neverStoreFields);
        System.assertEquals(new Set<String>{ 'Case', 'Opportunity' }, org.watchedObjects);
        System.assertEquals(365, org.retentionDays);
        System.assertEquals('RFC3161', org.anchorProvider);
        System.assertEquals('AgentLedger_TSA', org.anchorNamedCredential);

        AgentLedgerSettings.Resolved caseAgent = AgentLedgerSettings.forAgent('  case-escalation-agent ');
        System.assertEquals('Anchored', caseAgent.mode, 'agent record matched case-insensitively and trimmed');
        System.assert(!caseAgent.rollBackOnLogFailure(), 'explicit Continue wins over the mode default');
        System.assertEquals(45, caseAgent.autoCloseMinutes, 'org-wide settings still come from Org_Default');

        System.assert(!AgentLedgerSettings.forAgent('quiet-agent').enabled);
        System.assertEquals('Tamper_Evident', AgentLedgerSettings.forAgent('inherit-agent').mode, 'blank mode inherits');
    }

    @isTest
    static void newRunsAreStampedWithTheAgentsMode() {
        useRecords('[{"DeveloperName":"Org_Default","Enabled__c":true,"Mode__c":"Activity_Log"},' +
                   '{"DeveloperName":"Strict","Agent_Api_Name__c":"strict-agent","Enabled__c":true,"Mode__c":"Tamper_Evident"}]');
        Id logRun = AgentAuditRecorder.startSession('some-agent', CASE_ID, 'agentforce');
        Id strictRun = AgentAuditRecorder.startSession('strict-agent', CASE_ID, 'agentforce');
        System.assertEquals('Activity_Log', [SELECT Mode__c FROM Agent_Audit_Session__c WHERE Id = :logRun].Mode__c);
        System.assertEquals('Tamper_Evident', [SELECT Mode__c FROM Agent_Audit_Session__c WHERE Id = :strictRun].Mode__c);
    }

    @isTest
    static void aTurnedOffAgentRecordsNothingAndNeverFails() {
        useRecords('[{"DeveloperName":"Org_Default","Enabled__c":true},' +
                   '{"DeveloperName":"Off","Agent_Api_Name__c":"off-agent","Enabled__c":false}]');

        System.assertEquals(null, AgentLedgerRuns.findOrStart('off-agent', CASE_ID), 'no run for a turned-off agent');

        RecordAgentActionAction.Request rec = new RecordAgentActionAction.Request();
        rec.sessionId = null;
        rec.agentId = 'off-agent';
        rec.actionType = 'Decision';
        rec.reasoning = 'Would have been recorded';
        System.assert(RecordAgentActionAction.execute(new List<RecordAgentActionAction.Request>{ rec })[0].success);

        SealAgentLedgerSessionAction.Request seal = new SealAgentLedgerSessionAction.Request();
        seal.sessionId = null;
        System.assert(SealAgentLedgerSessionAction.execute(new List<SealAgentLedgerSessionAction.Request>{ seal })[0].success);

        System.assertEquals(0, [SELECT COUNT() FROM Agent_Audit_Session__c]);
        System.assertEquals(0, [SELECT COUNT() FROM Agent_Audit_Record__c]);

        // For an agent that records, a missing Session Id opens a run.
        rec.agentId = 'recording-agent';
        RecordAgentActionAction.Result opened = RecordAgentActionAction.execute(new List<RecordAgentActionAction.Request>{ rec })[0];
        System.assert(opened.success, opened.errorMessage);
        System.assertEquals(1, [SELECT COUNT() FROM Agent_Audit_Session__c WHERE Agent_Id__c = 'recording-agent']);
    }

    @isTest
    static void theDeployedOrgDefaultIsUsed() {
        // Without test records, the org's own Org_Default record applies.
        AgentLedgerSettings.Resolved r = AgentLedgerSettings.orgDefault();
        System.assertNotEquals(null, r.mode);
        System.assertNotEquals(null, r.autoCloseMinutes);
    }
}
