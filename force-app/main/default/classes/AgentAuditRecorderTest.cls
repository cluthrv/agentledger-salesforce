@IsTest
private class AgentAuditRecorderTest {

    @IsTest
    static void testFullLifecycleStartRecordSealVerify() {
        AgentAuditModels.StartSessionRequest startReq = new AgentAuditModels.StartSessionRequest();
        startReq.agentName = 'Opportunity Qualifier Agent';
        startReq.agentType = 'Agentforce';
        startReq.useCaseLabel = 'Opportunity Qualification';
        startReq.relatedRecordId = '006000000000001AAA';
        startReq.relatedObjectApiName = 'Opportunity';
        startReq.platform = 'Agentforce';
        startReq.externalCorrelationId = 'RUN-001';
        startReq.sessionNotes = 'Test session';

        Test.startTest();

        AgentAuditModels.StartSessionResult startResult = AgentAuditRecorder.startSession(startReq);

        System.assertEquals(true, startResult.success);
        System.assertNotEquals(null, startResult.sessionId);
        System.assertNotEquals(null, startResult.sessionUUID);

        for (Integer i = 1; i <= 3; i++) {
            AgentAuditModels.RecordActionRequest recordReq = new AgentAuditModels.RecordActionRequest();
            recordReq.sessionId = startResult.sessionId;
            recordReq.actionType = i == 1 ? 'Observation' : 'Decision';
            recordReq.actionLabel = 'Step ' + i;
            recordReq.decisionCategory = 'Recommendation';
            recordReq.riskLevel = 'Medium';
            recordReq.targetRecordId = '006000000000001AAA';
            recordReq.targetObjectApiName = 'Opportunity';
            recordReq.inputContext = 'Input context ' + i;
            recordReq.outputResult = 'Output result ' + i;
            recordReq.reasoning = 'Reasoning ' + i;

            AgentAuditModels.RecordActionResult recordResult = AgentAuditRecorder.recordAction(recordReq);

            System.assertEquals(true, recordResult.success);
            System.assertNotEquals(null, recordResult.auditRecordId);
            System.assertEquals(i, recordResult.sequenceNumber);
            System.assertEquals(64, recordResult.recordHash.length());
        }

        AgentAuditModels.SealSessionRequest sealReq = new AgentAuditModels.SealSessionRequest();
        sealReq.sessionId = startResult.sessionId;

        AgentAuditModels.SealSessionResult sealResult = AgentAuditRecorder.sealSession(sealReq);

        System.assertEquals(true, sealResult.success);
        System.assertEquals(startResult.sessionId, sealResult.sessionId);
        System.assertEquals(3, sealResult.recordCount);
        System.assertEquals(64, sealResult.merkleRoot.length());

        AgentAuditModels.VerifySessionRequest verifyReq = new AgentAuditModels.VerifySessionRequest();
        verifyReq.sessionId = startResult.sessionId;

        AgentAuditModels.VerifySessionResult verifyResult = AgentAuditRecorder.verifySession(verifyReq);

        Test.stopTest();

        System.assertEquals(true, verifyResult.verified);
        System.assertEquals('Verified', verifyResult.verificationStatus);
        System.assertEquals(3, verifyResult.recordCount);

        Agent_Audit_Session__c sessionRecord = [
            SELECT Status__c, Verification_Status__c, Record_Count__c, Merkle_Root__c
            FROM Agent_Audit_Session__c
            WHERE Id = :startResult.sessionId
            LIMIT 1
        ];

        System.assertEquals('Sealed', sessionRecord.Status__c);
        System.assertEquals('Verified', sessionRecord.Verification_Status__c);
        System.assertEquals(3, sessionRecord.Record_Count__c);
        System.assertNotEquals(null, sessionRecord.Merkle_Root__c);
    }

    @IsTest
    static void testStartSessionRequiresAgentName() {
        AgentAuditModels.StartSessionResult result = AgentAuditRecorder.startSession(
            new AgentAuditModels.StartSessionRequest()
        );

        System.assertEquals(false, result.success);
        System.assertEquals('agentName is required.', result.errorMessage);
    }

    @IsTest
    static void testRecordActionRequiresSessionId() {
        AgentAuditModels.RecordActionRequest req = new AgentAuditModels.RecordActionRequest();
        req.actionType = 'Decision';
        req.actionLabel = 'Missing Session';

        AgentAuditModels.RecordActionResult result = AgentAuditRecorder.recordAction(req);

        System.assertEquals(false, result.success);
        System.assertEquals('sessionId is required.', result.errorMessage);
    }

    @IsTest
    static void testTamperDetection() {
        AgentAuditModels.StartSessionRequest startReq = new AgentAuditModels.StartSessionRequest();
        startReq.agentName = 'Tamper Test Agent';

        AgentAuditModels.StartSessionResult startResult = AgentAuditRecorder.startSession(startReq);
        System.assertEquals(true, startResult.success);

        AgentAuditModels.RecordActionRequest recordReq = new AgentAuditModels.RecordActionRequest();
        recordReq.sessionId = startResult.sessionId;
        recordReq.actionType = 'Decision';
        recordReq.actionLabel = 'Original Decision';
        recordReq.decisionCategory = 'Other';
        recordReq.riskLevel = 'Low';
        recordReq.inputContext = 'Original input';
        recordReq.outputResult = 'Original output';
        recordReq.reasoning = 'Original reasoning';

        AgentAuditModels.RecordActionResult recordResult = AgentAuditRecorder.recordAction(recordReq);
        System.assertEquals(true, recordResult.success);

        AgentAuditModels.SealSessionRequest sealReq = new AgentAuditModels.SealSessionRequest();
        sealReq.sessionId = startResult.sessionId;
        AgentAuditRecorder.sealSession(sealReq);

        Agent_Audit_Record__c auditRecord = [
            SELECT Id, Reasoning__c
            FROM Agent_Audit_Record__c
            WHERE Audit_Session__c = :startResult.sessionId
            LIMIT 1
        ];
        auditRecord.Reasoning__c = 'Tampered reasoning';
        update auditRecord;

        AgentAuditModels.VerifySessionRequest verifyReq = new AgentAuditModels.VerifySessionRequest();
        verifyReq.sessionId = startResult.sessionId;

        AgentAuditModels.VerifySessionResult verifyResult = AgentAuditRecorder.verifySession(verifyReq);

        System.assertEquals(false, verifyResult.verified);
        System.assertEquals('Tampered', verifyResult.verificationStatus);
    }
}