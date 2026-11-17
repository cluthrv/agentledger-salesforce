/**
 * AgentLedgerReviewFixesTest
 *
 * Fixes from the November 2026 repository review: steps on records the viewer
 * cannot read, "never store" values in the logged request, changes automation
 * makes to other records during a recorded change, the displayed time against
 * the hashed time, and one-to-one matching in Check history.
 */
@isTest
private class AgentLedgerReviewFixesTest {

    private static final String AGENT = 'CaseEscalationAgent';

    private static void settings(String extraOrgJson) {
        AgentLedgerSettings.recordsForTest = (List<AgentLedger_Setting__mdt>) System.JSON.deserialize(
            '[{"DeveloperName":"Org_Default","Enabled__c":true,"Mode__c":"Tamper_Evident","Store_Field_Values__c":true'
            + (extraOrgJson == null ? '' : ',' + extraOrgJson) + '}]',
            List<AgentLedger_Setting__mdt>.class);
        AgentLedgerPolicy.definitionsForTest = new Map<String, AgentLedgerPolicy.AgentDefinition>();
    }

    private static UpdateRecordAgentLedgerAction.Result updateRecord(Id recordId, String fieldValues, Id sessionId) {
        UpdateRecordAgentLedgerAction.Request req = new UpdateRecordAgentLedgerAction.Request();
        req.recordId = recordId;
        req.fieldValues = fieldValues;
        req.reasoning = 'Qualifies under the escalation policy.';
        req.agentId = AGENT;
        req.sessionId = sessionId;
        UpdateRecordAgentLedgerAction.Result res = UpdateRecordAgentLedgerAction.execute(
            new List<UpdateRecordAgentLedgerAction.Request>{ req })[0];
        System.assert(res.success, res.errorMessage);
        return res;
    }

    // ── Steps on records the viewer cannot read ──

    @isTest
    static void stepsOnRecordsTheViewerCannotReadShowNoContent() {
        settings(null);
        Case a = new Case(Subject = 'Visible case', Status = 'New', Origin = 'Web');
        Case b = new Case(Subject = 'Restricted case', Status = 'New', Priority = 'Low', Origin = 'Web');
        insert new List<Case>{ a, b };
        Id runId = updateRecord(a.Id, '{"Status": "Escalated"}', null).sessionId;
        System.assertEquals(runId, updateRecord(b.Id, '{"Priority": "High"}', runId).sessionId, 'one run, two records');

        AgentLedgerAccess.readAccessForTest = new Map<Id, Boolean>{ a.Id => true, b.Id => false };

        AgentLedgerTimelineController.Timeline t = AgentLedgerTimelineController.getTimeline(a.Id, 10, null);
        System.assertEquals(1, t.runs.size());
        System.assertEquals(2, t.runs[0].entries.size(), 'the restricted step is still counted');
        AgentLedgerTimelineController.EntryView restricted = t.runs[0].entries[1];
        System.assertEquals(AgentLedgerTimelineController.RESTRICTED_SUMMARY, restricted.summary);
        System.assertEquals(null, restricted.reasoning);
        System.assertEquals(null, restricted.inputContext);
        System.assertEquals(null, restricted.outputResult);
        System.assertEquals(null, restricted.targetRecordId);
        System.assert(restricted.fieldChanges.isEmpty());
        String shown = JSON.serialize(t);
        System.assert(!shown.contains(String.valueOf(b.Id)) && !shown.contains(String.valueOf(b.Id).left(15)), shown);
        System.assert(!shown.contains('Priority'), shown);

        AgentAuditRecorder.sealSession(runId);
        AgentLedgerEvidence.ExportedRun exported = AgentLedgerEvidence.build(runId);
        System.assertEquals(1, exported.hiddenEntries);
        System.assert(!exported.json.contains(String.valueOf(b.Id).left(15)), 'the restricted record is not named');
        System.assert(!exported.json.contains('Priority'), 'nor are its values');
    }

    @isTest
    static void checkHistoryLeavesOutRecordsTheViewerCannotRead() {
        settings(null);
        Case a = new Case(Subject = 'Visible case', Status = 'New', Origin = 'Web');
        Case b = new Case(Subject = 'Restricted case', Status = 'New', Priority = 'Low', Origin = 'Web');
        insert new List<Case>{ a, b };
        Id runId = updateRecord(a.Id, '{"Status": "Escalated"}', null).sessionId;
        updateRecord(b.Id, '{"Priority": "High"}', runId);
        AgentAuditRecorder.sealSession(runId);
        DateTime during = [SELECT Start_Time__c FROM Agent_Audit_Session__c WHERE Id = :runId].Start_Time__c;

        AgentLedgerAccess.readAccessForTest = new Map<Id, Boolean>{ a.Id => true, b.Id => false };
        AgentLedgerReconciliation.historyForTest = new List<AgentLedgerReconciliation.HistoryRow>{
            new AgentLedgerReconciliation.HistoryRow(b.Id, 'Subject', 'x', 'y', during)
        };
        AgentLedgerReconciliation.Result r = AgentLedgerReconciliation.reconcileRun(runId);
        System.assertEquals(1, r.recordsChecked);
        System.assert(r.missing.isEmpty(), 'nothing from the restricted record');
        System.assert(r.summary.contains('not checked because you do not have access'), r.summary);
    }

    // ── "Never store" values ──

    @isTest
    static void neverStoreValuesStayOutOfTheLoggedRequest() {
        settings('"Never_Store_Fields__c":"Case.Description"');
        Case c = new Case(Subject = 'Privacy', Status = 'New', Origin = 'Web');
        insert c;
        Id runId = updateRecord(c.Id, '{"Status": "Escalated", "description": "SECRET-123"}', null).sessionId;

        CreateRecordAgentLedgerAction.Request create = new CreateRecordAgentLedgerAction.Request();
        create.objectApiName = 'Case';
        create.fieldValues = '{"Subject": "Follow-up", "Description": "SECRET-456", "Origin": "Web"}';
        create.reasoning = 'A follow-up is needed.';
        create.agentId = AGENT;
        create.sessionId = runId;
        CreateRecordAgentLedgerAction.Result created = CreateRecordAgentLedgerAction.execute(
            new List<CreateRecordAgentLedgerAction.Request>{ create })[0];
        System.assert(created.success, created.errorMessage);

        for (Agent_Audit_Record__c e : [
            SELECT Input_Context__c, Output_Result__c, Summary__c, Field_Changes__c
            FROM Agent_Audit_Record__c WHERE Audit_Session__c = :runId
        ]) {
            String all = e.Input_Context__c + e.Output_Result__c + e.Summary__c + e.Field_Changes__c;
            System.assert(!all.contains('SECRET'), all);
        }
        Agent_Audit_Record__c first = [
            SELECT Input_Context__c FROM Agent_Audit_Record__c WHERE Audit_Session__c = :runId AND Sequence_Number__c = 0
        ];
        System.assert(first.Input_Context__c.contains('"Status":"Escalated"'), first.Input_Context__c);
        System.assert(first.Input_Context__c.contains(AgentLedgerRecordSupport.NOT_STORED), first.Input_Context__c);
    }

    // ── Changes automation makes to other records ──

    @isTest
    static void automationChangesToOtherRecordsAreCollectedForTheRun() {
        settings(null);
        Case target = new Case(Subject = 'Agent target', Status = 'New', Origin = 'Web');
        Case other = new Case(Subject = 'Changed by a flow', Status = 'New', Priority = 'Low', Origin = 'Web');
        insert new List<Case>{ target, other };

        // What a flow or trigger does during the agent's change.
        AgentLedgerGuard.beginRecordedChange(target.Id, AGENT);
        try {
            update new Case(Id = target.Id, Status = 'Escalated');
            update new Case(Id = other.Id, Priority = 'High');
        } finally {
            AgentLedgerGuard.endRecordedChange();
        }
        List<AgentAuditRecorder.EntryInput> effects = AgentLedgerGuard.takeSideEffects(target.Id);
        System.assertEquals(1, effects.size(), 'the target is logged by the action, not here');
        System.assertEquals(String.valueOf(other.Id), effects[0].targetRecordId);
        System.assertEquals(AgentLedgerChangeDetector.CAPTURE_METHOD, effects[0].captureMethod);
        System.assertEquals(AgentLedgerChangeDetector.AUTOMATION_REASON, effects[0].reasoning);
        System.assert(effects[0].summary.contains('by automation'), effects[0].summary);
        System.assert(effects[0].outputResult.contains('Low → High'), effects[0].outputResult);
        System.assert(AgentLedgerGuard.takeSideEffects(null).isEmpty(), 'taken once');
        System.assertEquals(0, [SELECT COUNT() FROM Agent_Audit_Record__c], 'nothing written by the detector itself');
    }

    @isTest
    static void aCreatedRecordIsNotItsOwnSideEffect() {
        settings(null);
        AgentLedgerGuard.beginRecordedChange(null, AGENT);
        Case c = new Case(Subject = 'Created by the agent', Status = 'New', Origin = 'Web');
        try {
            insert c;
        } finally {
            AgentLedgerGuard.endRecordedChange();
        }
        System.assert(AgentLedgerGuard.takeSideEffects(c.Id).isEmpty());
    }

    // ── Displayed time against hashed time ──

    @isTest
    static void aChangedDisplayTimeFailsVerification() {
        settings(null);
        Case c = new Case(Subject = 'Time', Status = 'New', Origin = 'Web');
        insert c;
        Id runId = updateRecord(c.Id, '{"Status": "Escalated"}', null).sessionId;
        AgentAuditRecorder.sealSession(runId);
        System.assert(AgentAuditRecorder.verifySession(runId).valid);

        Agent_Audit_Record__c e = [SELECT Id, Action_Timestamp__c FROM Agent_Audit_Record__c WHERE Audit_Session__c = :runId LIMIT 1];
        AgentLedgerGuard.allowManualEditsForTest = true;
        update new Agent_Audit_Record__c(Id = e.Id, Action_Timestamp__c = e.Action_Timestamp__c.addHours(-3));
        AgentLedgerGuard.allowManualEditsForTest = false;

        System.assert(!AgentAuditRecorder.verifySession(runId).valid, 'the hash still matches, the shown time does not');
    }

    // ── Check history: one logged change per history row ──

    @isTest
    static void twoChangesToOneFieldNeedTwoLoggedChanges() {
        settings(null);
        Case c = new Case(Subject = 'Twice', Status = 'New', Origin = 'Web');
        insert c;
        Id runId = updateRecord(c.Id, '{"Status": "Escalated"}', null).sessionId;
        AgentAuditRecorder.sealSession(runId);
        DateTime during = [SELECT Start_Time__c FROM Agent_Audit_Session__c WHERE Id = :runId].Start_Time__c;

        AgentLedgerReconciliation.historyForTest = new List<AgentLedgerReconciliation.HistoryRow>{
            new AgentLedgerReconciliation.HistoryRow(c.Id, 'Status', 'Escalated', 'Working', during.addSeconds(2)),
            new AgentLedgerReconciliation.HistoryRow(c.Id, 'Status', 'New', 'Escalated', during)
        };
        AgentLedgerReconciliation.Result r = AgentLedgerReconciliation.reconcileRun(runId);
        System.assertEquals(2, r.historyChanges);
        System.assertEquals(1, r.matched);
        System.assertEquals(1, r.missing.size());
        System.assertEquals('Working', r.missing[0].after, 'the later change is the one not in the log');
    }
}
