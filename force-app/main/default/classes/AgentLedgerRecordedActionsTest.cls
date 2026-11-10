/**
 * AgentLedgerRecordedActionsTest
 *
 * Phase 1 step 4: Get, Update and Create Record (AgentLedger), automatic runs,
 * the "If Logging Fails" setting, privacy settings, and auto-close.
 */
@isTest
private class AgentLedgerRecordedActionsTest {

    private static final String AGENT = 'case-escalation-agent';

    private static void settings(String orgMode, String extraOrgJson) {
        AgentLedgerSettings.recordsForTest = (List<AgentLedger_Setting__mdt>) System.JSON.deserialize(
            '[{"DeveloperName":"Org_Default","Enabled__c":true,"Mode__c":"' + orgMode + '","Store_Field_Values__c":true' +
            (extraOrgJson == null ? '' : ',' + extraOrgJson) + '},' +
            '{"DeveloperName":"Off","Agent_Api_Name__c":"off-agent","Enabled__c":false}]',
            List<AgentLedger_Setting__mdt>.class);
    }

    private static Case newCase() {
        Case c = new Case(Subject = 'Generator assembly unclear', Status = 'New', Priority = 'Medium', Origin = 'Web');
        insert c;
        return c;
    }

    private static UpdateRecordAgentLedgerAction.Result updateCase(Id caseId, String fieldValues, String agentId, Id sessionId) {
        UpdateRecordAgentLedgerAction.Request req = new UpdateRecordAgentLedgerAction.Request();
        req.recordId = caseId;
        req.fieldValues = fieldValues;
        req.reasoning = 'High priority and not yet escalated.';
        req.agentId = agentId;
        req.sessionId = sessionId;
        return UpdateRecordAgentLedgerAction.execute(new List<UpdateRecordAgentLedgerAction.Request>{ req })[0];
    }

    @isTest
    static void updateChangesTheRecordAndLogsBeforeAndAfter() {
        settings('Tamper_Evident', null);
        Case c = newCase();

        UpdateRecordAgentLedgerAction.Result res = updateCase(c.Id, '{"Status": "Escalated", "priority": "High"}', AGENT, null);
        System.assert(res.success, res.errorMessage);
        System.assert(res.logged);
        System.assert(res.changes.contains('Status: New → Escalated'), res.changes);

        Case after = [SELECT Status, Priority FROM Case WHERE Id = :c.Id];
        System.assertEquals('Escalated', after.Status);
        System.assertEquals('High', after.Priority);

        Agent_Audit_Record__c entry = [SELECT Action_Type__c, Capture_Method__c, Target_Record_Id__c, Target_Object__c,
                                       Field_Changes__c, Summary__c, Reasoning__c, Audit_Session__c
                                       FROM Agent_Audit_Record__c WHERE Audit_Session__c = :res.sessionId];
        System.assertEquals('Data_Change', entry.Action_Type__c);
        System.assertEquals('Recorded_Action', entry.Capture_Method__c);
        System.assertEquals(String.valueOf(c.Id), entry.Target_Record_Id__c);
        System.assertEquals('Case', entry.Target_Object__c);
        System.assert(entry.Summary__c.startsWith('Updated Case '), entry.Summary__c);

        List<Object> changes = (List<Object>) System.JSON.deserializeUntyped(entry.Field_Changes__c);
        System.assertEquals(2, changes.size());
        Map<String, Object> status = (Map<String, Object>) changes[0];
        if (status.get('field') != 'Status') {
            status = (Map<String, Object>) changes[1];
        }
        System.assertEquals('New', status.get('before'));
        System.assertEquals('Escalated', status.get('after'));

        Agent_Audit_Session__c run = [SELECT Related_Record_Id__c, Mode__c FROM Agent_Audit_Session__c WHERE Id = :res.sessionId];
        System.assertEquals(String.valueOf(c.Id), run.Related_Record_Id__c, 'the run is about the updated record');
        System.assertEquals('Tamper_Evident', run.Mode__c);

        AgentAuditRecorder.sealSession(res.sessionId);
        System.assert(AgentAuditRecorder.verifySession(res.sessionId).valid);
    }

    @isTest
    static void stepsOfOneConversationShareARun() {
        settings('Activity_Log', null);
        Case c = newCase();

        GetRecordAgentLedgerAction.Request get = new GetRecordAgentLedgerAction.Request();
        get.recordId = c.Id;
        get.fields = 'Status, Priority, Subject';
        get.agentId = AGENT;
        GetRecordAgentLedgerAction.Result got = GetRecordAgentLedgerAction.execute(new List<GetRecordAgentLedgerAction.Request>{ get })[0];
        System.assert(got.success, got.errorMessage);
        Map<String, Object> values = (Map<String, Object>) System.JSON.deserializeUntyped(got.recordJson);
        System.assertEquals('Medium', values.get('Priority'));

        UpdateRecordAgentLedgerAction.Result updated = updateCase(c.Id, '{"Status": "Escalated"}', AGENT, null);
        System.assertEquals(got.sessionId, updated.sessionId, 'lookup and update are in the same run');
        System.assertEquals(2, [SELECT COUNT() FROM Agent_Audit_Record__c WHERE Audit_Session__c = :got.sessionId]);

        // Another record starts its own run.
        Case other = newCase();
        System.assertNotEquals(got.sessionId, updateCase(other.Id, '{"Status": "Escalated"}', AGENT, null).sessionId);
    }

    @isTest
    static void invalidRequestsChangeNothingAndLogNothing() {
        settings('Activity_Log', null);
        Case c = newCase();

        UpdateRecordAgentLedgerAction.Result unknownField = updateCase(c.Id, '{"NotAField__c": "x"}', AGENT, null);
        System.assert(!unknownField.success);
        System.assert(unknownField.errorMessage.contains('no field named'), unknownField.errorMessage);

        UpdateRecordAgentLedgerAction.Result notJson = updateCase(c.Id, 'Status = Escalated', AGENT, null);
        System.assert(!notJson.success);
        System.assert(notJson.errorMessage.contains('JSON'), notJson.errorMessage);

        UpdateRecordAgentLedgerAction.Result badDate = updateCase(c.Id, '{"Status": "Escalated", "ClosedDate": "not a date"}', AGENT, null);
        System.assert(!badDate.success);

        System.assertEquals('New', [SELECT Status FROM Case WHERE Id = :c.Id].Status);
        System.assertEquals(0, [SELECT COUNT() FROM Agent_Audit_Record__c]);
    }

    @isTest
    static void noChangeIsStillLogged() {
        settings('Activity_Log', null);
        Case c = newCase();
        UpdateRecordAgentLedgerAction.Result res = updateCase(c.Id, '{"Status": "New"}', AGENT, null);
        System.assert(res.success, res.errorMessage);
        System.assert(res.changes.startsWith('No change'), res.changes);
        System.assertEquals(1, [SELECT COUNT() FROM Agent_Audit_Record__c]);
    }

    @isTest
    static void inTamperModesAChangeThatCannotBeLoggedIsRolledBack() {
        settings('Tamper_Evident', null);
        Case c = newCase();
        Id closedRun = AgentAuditRecorder.startSession(AGENT, c.Id, 'agentforce');
        AgentAuditRecorder.recordAction(closedRun, AGENT, 'Query', 'in', 'out', 'first step');
        AgentAuditRecorder.sealSession(closedRun);

        UpdateRecordAgentLedgerAction.Result res = updateCase(c.Id, '{"Status": "Escalated"}', AGENT, closedRun);
        System.assert(!res.success);
        System.assert(res.errorMessage.startsWith('The change was not made because it could not be logged'), res.errorMessage);
        System.assertEquals('New', [SELECT Status FROM Case WHERE Id = :c.Id].Status, 'the change was rolled back');
    }

    @isTest
    static void inActivityLogModeAChangeThatCannotBeLoggedIsKept() {
        settings('Activity_Log', null);
        Case c = newCase();
        Id closedRun = AgentAuditRecorder.startSession(AGENT, c.Id, 'agentforce');
        AgentAuditRecorder.recordAction(closedRun, AGENT, 'Query', 'in', 'out', 'first step');
        AgentAuditRecorder.sealSession(closedRun);

        UpdateRecordAgentLedgerAction.Result res = updateCase(c.Id, '{"Status": "Escalated"}', AGENT, closedRun);
        System.assert(res.success);
        System.assert(!res.logged);
        System.assert(res.errorMessage.startsWith('The change was made but could not be logged'), res.errorMessage);
        System.assertEquals('Escalated', [SELECT Status FROM Case WHERE Id = :c.Id].Status);
    }

    @isTest
    static void privacySettingsKeepValuesOutOfTheLog() {
        settings('Activity_Log', '"Never_Store_Fields__c":"Case.Subject"');
        Case c = newCase();
        UpdateRecordAgentLedgerAction.Result res = updateCase(c.Id, '{"Subject": "Customer SSN 123-45-6789", "Status": "Escalated"}', AGENT, null);
        System.assert(res.success, res.errorMessage);
        String stored = [SELECT Field_Changes__c FROM Agent_Audit_Record__c WHERE Audit_Session__c = :res.sessionId].Field_Changes__c;
        System.assert(!stored.contains('123-45-6789'), 'a never-store field keeps its value out of the log');
        System.assert(stored.contains(AgentLedgerRecordSupport.NOT_STORED));
        System.assert(stored.contains('Escalated'), 'other fields are stored');
    }

    @isTest
    static void aTurnedOffAgentStillUpdatesButLogsNothing() {
        settings('Activity_Log', null);
        Case c = newCase();
        UpdateRecordAgentLedgerAction.Result res = updateCase(c.Id, '{"Status": "Escalated"}', 'off-agent', null);
        System.assert(res.success, res.errorMessage);
        System.assertEquals(null, res.sessionId);
        System.assertEquals('Escalated', [SELECT Status FROM Case WHERE Id = :c.Id].Status);
        System.assertEquals(0, [SELECT COUNT() FROM Agent_Audit_Session__c]);
    }

    @isTest
    static void createMakesTheRecordAndLogsIt() {
        settings('Activity_Log', null);
        Case parent = newCase();
        CreateRecordAgentLedgerAction.Request req = new CreateRecordAgentLedgerAction.Request();
        req.objectApiName = 'Task';
        req.fieldValues = '{"Subject": "Call the customer about the escalation", "WhatId": "' + parent.Id + '", "Status": "Not Started", "ActivityDate": "2026-11-20"}';
        req.reasoning = 'The customer should hear about the escalation today.';
        req.agentId = AGENT;
        req.relatedRecordId = parent.Id;
        CreateRecordAgentLedgerAction.Result res = CreateRecordAgentLedgerAction.execute(new List<CreateRecordAgentLedgerAction.Request>{ req })[0];
        System.assert(res.success, res.errorMessage);
        System.assert(res.logged);
        System.assertEquals(Date.newInstance(2026, 11, 20), [SELECT ActivityDate FROM Task WHERE Id = :res.recordId].ActivityDate);

        Agent_Audit_Record__c entry = [SELECT Action_Type__c, Target_Object__c, Target_Record_Id__c, Field_Changes__c
                                       FROM Agent_Audit_Record__c WHERE Audit_Session__c = :res.sessionId];
        System.assertEquals('Create', entry.Action_Type__c);
        System.assertEquals('Task', entry.Target_Object__c);
        System.assertEquals(String.valueOf(res.recordId), entry.Target_Record_Id__c);
        System.assertEquals(String.valueOf(parent.Id),
            [SELECT Related_Record_Id__c FROM Agent_Audit_Session__c WHERE Id = :res.sessionId].Related_Record_Id__c,
            'the run appears on the related record');

        req.objectApiName = 'NoSuchObject__c';
        System.assert(!CreateRecordAgentLedgerAction.execute(new List<CreateRecordAgentLedgerAction.Request>{ req })[0].success);
    }

    @isTest
    static void getWithoutFieldsReadsAccessibleFields() {
        settings('Activity_Log', null);
        Case c = newCase();
        GetRecordAgentLedgerAction.Request get = new GetRecordAgentLedgerAction.Request();
        get.recordId = c.Id;
        get.agentId = AGENT;
        GetRecordAgentLedgerAction.Result got = GetRecordAgentLedgerAction.execute(new List<GetRecordAgentLedgerAction.Request>{ get })[0];
        System.assert(got.success, got.errorMessage);
        System.assert(((Map<String, Object>) System.JSON.deserializeUntyped(got.recordJson)).containsKey('Subject'));

        get.fields = 'Status, NotAField';
        System.assert(!GetRecordAgentLedgerAction.execute(new List<GetRecordAgentLedgerAction.Request>{ get })[0].success);
    }

    @isTest
    static void autoCloseMarksInactiveRunsIncomplete() {
        settings('Tamper_Evident', '"Auto_Close_Minutes__c":30');
        Case c = newCase();
        Id withEntries = AgentAuditRecorder.startSession(AGENT, c.Id, 'agentforce');
        AgentAuditRecorder.recordAction(withEntries, AGENT, 'Query', 'in', 'out', 'looked');
        Id empty = AgentAuditRecorder.startSession(AGENT, c.Id, 'agentforce');
        Id recent = AgentAuditRecorder.startSession(AGENT, c.Id, 'agentforce');

        AgentLedgerGuard.allowManualEditsForTest = true; // age two runs
        update new List<Agent_Audit_Session__c>{
            new Agent_Audit_Session__c(Id = withEntries, Last_Activity__c = DateTime.now().addHours(-2)),
            new Agent_Audit_Session__c(Id = empty, Last_Activity__c = DateTime.now().addHours(-2))
        };
        AgentLedgerGuard.allowManualEditsForTest = false;

        Test.startTest();
        Database.executeBatch(new AgentLedgerAutoClose(), AgentLedgerAutoClose.BATCH_SIZE);
        Test.stopTest();

        Agent_Audit_Session__c closed = [SELECT Status__c, Merkle_Root__c FROM Agent_Audit_Session__c WHERE Id = :withEntries];
        System.assertEquals('Incomplete', closed.Status__c);
        System.assertNotEquals(null, closed.Merkle_Root__c, 'a run with entries is sealed');
        System.assert(AgentAuditRecorder.verifySession(withEntries).valid);
        System.assertEquals('Incomplete', [SELECT Status__c FROM Agent_Audit_Session__c WHERE Id = :empty].Status__c);
        System.assertEquals('Active', [SELECT Status__c FROM Agent_Audit_Session__c WHERE Id = :recent].Status__c, 'recent runs stay open');
    }

    @isTest
    static void autoCloseCanBeScheduled() {
        Test.startTest();
        Id jobId = AgentLedgerAutoClose.scheduleHourly();
        Test.stopTest();
        System.assertNotEquals(null, jobId);
        System.assertEquals('0 0 * * * ?', [SELECT CronExpression FROM CronTrigger WHERE Id = :jobId].CronExpression);
    }

    @isTest
    static void theSchedulerStartsAutoCloseByName() {
        Test.startTest();
        new AgentLedgerScheduler().execute(null);
        Test.stopTest();
        System.assertEquals(1, [SELECT COUNT() FROM AsyncApexJob WHERE ApexClass.Name = 'AgentLedgerAutoClose' AND JobType = 'BatchApex']);
    }
}
