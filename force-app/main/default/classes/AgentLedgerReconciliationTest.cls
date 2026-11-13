/**
 * AgentLedgerReconciliationTest
 *
 * Field history rows cannot be created in tests, so historyForTest supplies
 * them; the query path runs against the real CaseHistory table.
 */
@isTest
private class AgentLedgerReconciliationTest {

    private static final String AGENT = 'CaseEscalationAgent';

    private static void settings() {
        AgentLedgerSettings.recordsForTest = (List<AgentLedger_Setting__mdt>) System.JSON.deserialize(
            '[{"DeveloperName":"Org_Default","Enabled__c":true,"Mode__c":"Tamper_Evident","Store_Field_Values__c":true}]',
            List<AgentLedger_Setting__mdt>.class);
        AgentLedgerPolicy.definitionsForTest = new Map<String, AgentLedgerPolicy.AgentDefinition>();
    }

    /** A closed run that changed Status on a Case through the recorded action. */
    private static Id escalated(Case c) {
        UpdateRecordAgentLedgerAction.Request u = new UpdateRecordAgentLedgerAction.Request();
        u.agentId = AGENT; u.recordId = c.Id; u.fieldValues = '{"Status": "Escalated"}'; u.reasoning = 'qualifies';
        Id runId = UpdateRecordAgentLedgerAction.execute(new List<UpdateRecordAgentLedgerAction.Request>{ u })[0].sessionId;
        AgentAuditRecorder.sealSession(runId);
        return runId;
    }

    @isTest
    static void changesSalesforceRecordedButTheLogDoesNotHaveAreListed() {
        settings();
        Case c = new Case(Subject = 'Reconcile', Status = 'New', Priority = 'Low', Origin = 'Web');
        insert c;
        Id runId = escalated(c);
        DateTime during = [SELECT Start_Time__c FROM Agent_Audit_Session__c WHERE Id = :runId].Start_Time__c;

        AgentLedgerReconciliation.historyForTest = new List<AgentLedgerReconciliation.HistoryRow>{
            new AgentLedgerReconciliation.HistoryRow(c.Id, 'Status', 'New', 'Escalated', during),          // in the log
            new AgentLedgerReconciliation.HistoryRow(c.Id, 'Priority', 'Low', 'High', during),             // not in the log
            new AgentLedgerReconciliation.HistoryRow(c.Id, 'Owner', 'u1', 'u2', during.addSeconds(1)),     // a lookup: two rows,
            new AgentLedgerReconciliation.HistoryRow(c.Id, 'Owner', 'Ann', 'Bob', during.addSeconds(1)),   // one change
            new AgentLedgerReconciliation.HistoryRow(c.Id, 'created', null, null, during),                 // not a field change
            new AgentLedgerReconciliation.HistoryRow(c.Id, 'Subject', 'a', 'b', during.addDays(-1))        // before the run
        };
        AgentLedgerReconciliation.Result r = AgentLedgerReconciliation.reconcileRun(runId);
        System.assertEquals(1, r.recordsChecked);
        System.assertEquals(3, r.historyChanges, 'Status, Priority, Owner');
        System.assertEquals(1, r.matched);
        System.assertEquals(2, r.missing.size());
        System.assertEquals('Priority', r.missing[0].field);
        System.assertEquals('High', r.missing[0].after);
        System.assert(r.summary.startsWith('2 of 3'), r.summary);
    }

    @isTest
    static void aCompleteRunSaysSo() {
        settings();
        Case c = new Case(Subject = 'Reconcile', Status = 'New', Origin = 'Web');
        insert c;
        Id runId = escalated(c);
        DateTime during = [SELECT Start_Time__c FROM Agent_Audit_Session__c WHERE Id = :runId].Start_Time__c;
        AgentLedgerReconciliation.historyForTest = new List<AgentLedgerReconciliation.HistoryRow>{
            new AgentLedgerReconciliation.HistoryRow(c.Id, 'Status', 'New', 'Escalated', during)
        };
        AgentLedgerReconciliation.Result r = AgentLedgerReconciliation.reconcileRun(runId);
        System.assert(r.missing.isEmpty());
        System.assert(r.summary.startsWith('All 1 field change'), r.summary);
    }

    @isTest
    static void unreadableValuesAreHidden() {
        settings();
        Case c = new Case(Subject = 'Reconcile', Status = 'New', Origin = 'Web');
        insert c;
        Id runId = escalated(c);
        DateTime during = [SELECT Start_Time__c FROM Agent_Audit_Session__c WHERE Id = :runId].Start_Time__c;
        AgentLedgerReconciliation.historyForTest = new List<AgentLedgerReconciliation.HistoryRow>{
            new AgentLedgerReconciliation.HistoryRow(c.Id, 'Priority', 'Low', 'High', during)
        };
        AgentLedgerAccess.fieldReadableForTest = new Map<String, Boolean>{ 'priority' => false };
        AgentLedgerReconciliation.Missing m = AgentLedgerReconciliation.reconcileRun(runId).missing[0];
        System.assertEquals('[hidden]', m.before);
        System.assertEquals('[hidden]', m.after);
    }

    @isTest
    static void theRealHistoryTableIsQueried() {
        settings();
        Case c = new Case(Subject = 'Reconcile', Status = 'New', Origin = 'Web');
        insert c;
        Id runId = escalated(c);
        AgentLedgerReconciliation.Result r = AgentLedgerReconciliation.reconcileRun(runId); // CaseHistory: no rows in a test
        System.assertEquals(0, r.historyChanges);
        System.assert(r.summary.startsWith('Salesforce recorded no tracked field changes'), r.summary);
    }

    @isTest
    static void objectsWithoutHistoryAreReported() {
        settings();
        Case c = new Case(Subject = 'Reconcile', Status = 'New', Origin = 'Web');
        insert c;
        Id runId = escalated(c);
        Agent_Audit_Record__c e = [SELECT Id FROM Agent_Audit_Record__c WHERE Audit_Session__c = :runId LIMIT 1];
        AgentLedgerGuard.allowManualEditsForTest = true;
        update new Agent_Audit_Record__c(Id = e.Id, Target_Object__c = 'NoHistoryObject');
        AgentLedgerGuard.allowManualEditsForTest = false;
        AgentLedgerReconciliation.Result r = AgentLedgerReconciliation.reconcileRun(runId);
        System.assertEquals(new List<String>{ 'NoHistoryObject' }, r.notTracked, 'the entry now targets an object without a history table');
        System.assert(r.summary.contains('No field history for'), r.summary);
    }

    @isTest
    static void reconcilingNeedsAccessToTheRun() {
        settings();
        Case c = new Case(Subject = 'Reconcile', Status = 'New', Origin = 'Web');
        insert c;
        Id runId = escalated(c);
        AgentLedgerAccess.readAccessForTest = new Map<Id, Boolean>{ runId => false, c.Id => false };
        try {
            AgentLedgerReconciliation.reconcileRun(runId);
            System.assert(false, 'expected an error');
        } catch (AuraHandledException e) {
            System.assert(true);
        }
    }
}
