@IsTest
private class AgentAuditQueryServiceTest {

    @IsTest
    static void testQueryMethods() {
        AgentAuditModels.StartSessionRequest startReq = new AgentAuditModels.StartSessionRequest();
        startReq.agentName = 'Query Test Agent';
        startReq.agentType = 'Agentforce';
        startReq.useCaseLabel = 'Case Escalation';
        startReq.relatedRecordId = '500000000000001AAA';
        startReq.relatedObjectApiName = 'Case';
        startReq.platform = 'Agentforce';

        AgentAuditModels.StartSessionResult startResult = AgentAuditRecorder.startSession(startReq);
        System.assertEquals(true, startResult.success);

        AgentAuditModels.RecordActionRequest recordReq = new AgentAuditModels.RecordActionRequest();
        recordReq.sessionId = startResult.sessionId;
        recordReq.actionType = 'Decision';
        recordReq.actionLabel = 'Escalate Case';
        recordReq.decisionCategory = 'Escalation';
        recordReq.riskLevel = 'High';
        recordReq.targetRecordId = '500000000000001AAA';
        recordReq.targetObjectApiName = 'Case';
        recordReq.inputContext = 'Customer reported outage.';
        recordReq.outputResult = 'Escalate to Tier 2.';
        recordReq.reasoning = 'High impact customer issue.';

        AgentAuditModels.RecordActionResult recordResult = AgentAuditRecorder.recordAction(recordReq);
        System.assertEquals(true, recordResult.success);

        AgentAuditModels.SealSessionRequest sealReq = new AgentAuditModels.SealSessionRequest();
        sealReq.sessionId = startResult.sessionId;
        AgentAuditRecorder.sealSession(sealReq);

        List<Agent_Audit_Session__c> sessions =
            AgentAuditQueryService.getSessionsByRecord('500000000000001AAA', 10);

        System.assertEquals(1, sessions.size());
        System.assertEquals('Query Test Agent', sessions[0].Agent_Name__c);

        List<Agent_Audit_Record__c> records =
            AgentAuditQueryService.getRecordsBySession(startResult.sessionId);

        System.assertEquals(1, records.size());
        System.assertEquals('Escalate Case', records[0].Action_Label__c);

        Agent_Audit_Session__c summary =
            AgentAuditQueryService.getSessionSummary(startResult.sessionId);

        System.assertEquals('Case', summary.Related_Object_API_Name__c);

        AgentAuditQueryService.SessionFilterRequest filterReq =
            new AgentAuditQueryService.SessionFilterRequest();

        filterReq.agentName = 'Query';
        filterReq.objectApiName = 'Case';
        filterReq.status = 'Sealed';
        filterReq.verificationStatus = 'Unverified';
        filterReq.limitCount = 50;

        List<Agent_Audit_Session__c> filtered =
            AgentAuditQueryService.getAllSessionsFiltered(filterReq);

        System.assertEquals(1, filtered.size());
        System.assertEquals(startResult.sessionId, filtered[0].Id);
    }

    @IsTest
    static void testLimitNormalization() {
        AgentAuditModels.StartSessionRequest startReq = new AgentAuditModels.StartSessionRequest();
        startReq.agentName = 'Limit Test Agent';
        startReq.relatedRecordId = '001000000000001AAA';
        startReq.relatedObjectApiName = 'Account';

        AgentAuditModels.StartSessionResult startResult = AgentAuditRecorder.startSession(startReq);
        System.assertEquals(true, startResult.success);

        List<Agent_Audit_Session__c> sessions =
            AgentAuditQueryService.getSessionsByRecord('001000000000001AAA', null);

        System.assertEquals(1, sessions.size());

        AgentAuditQueryService.SessionFilterRequest filterReq =
            new AgentAuditQueryService.SessionFilterRequest();

        filterReq.limitCount = 9999;

        List<Agent_Audit_Session__c> filtered =
            AgentAuditQueryService.getAllSessionsFiltered(filterReq);

        System.assert(filtered.size() >= 1);
    }
}
