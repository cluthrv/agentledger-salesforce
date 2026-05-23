@IsTest
private class InvocableActionsTest {

    @IsTest
    static void testFullInvocableLifecycle() {
        StartSessionAction.Request startReq = new StartSessionAction.Request();
        startReq.agentName = 'Invocable Test Agent';
        startReq.agentType = 'Agentforce';
        startReq.useCaseLabel = 'Opportunity Qualification';
        startReq.relatedRecordId = '006000000000001AAA';
        startReq.relatedObjectApiName = 'Opportunity';
        startReq.platform = 'Agentforce';
        startReq.externalCorrelationId = 'INVOCABLE-RUN-001';
        startReq.sessionNotes = 'Invocable lifecycle test';

        List<StartSessionAction.Response> startResponses =
            StartSessionAction.invoke(new List<StartSessionAction.Request>{ startReq });

        System.assertEquals(1, startResponses.size());
        System.assertEquals(true, startResponses[0].success);
        System.assertNotEquals(null, startResponses[0].sessionId);
        System.assertNotEquals(null, startResponses[0].sessionUUID);

        RecordDecisionAction.Request decisionReq = new RecordDecisionAction.Request();
        decisionReq.sessionId = startResponses[0].sessionId;
        decisionReq.actionLabel = 'Opportunity Qualified';
        decisionReq.decisionCategory = 'Recommendation';
        decisionReq.riskLevel = 'Medium';
        decisionReq.targetRecordId = '006000000000001AAA';
        decisionReq.targetObjectApiName = 'Opportunity';
        decisionReq.inputContext = 'Opportunity has budget and timeline.';
        decisionReq.outputResult = 'Recommend qualification.';
        decisionReq.reasoning = 'Strong fit based on qualification criteria.';

        List<RecordDecisionAction.Response> decisionResponses =
            RecordDecisionAction.invoke(new List<RecordDecisionAction.Request>{ decisionReq });

        System.assertEquals(1, decisionResponses.size());
        System.assertEquals(true, decisionResponses[0].success);
        System.assertEquals(1, decisionResponses[0].sequenceNumber);
        System.assertEquals(64, decisionResponses[0].recordHash.length());

        RecordActionAction.Request actionReq = new RecordActionAction.Request();
        actionReq.sessionId = startResponses[0].sessionId;
        actionReq.actionLabel = 'Stage Updated';
        actionReq.decisionCategory = 'Recommendation';
        actionReq.riskLevel = 'Medium';
        actionReq.targetRecordId = '006000000000001AAA';
        actionReq.targetObjectApiName = 'Opportunity';
        actionReq.inputContext = 'Qualified recommendation accepted.';
        actionReq.outputResult = 'Stage changed to Proposal.';
        actionReq.reasoning = 'Agent executed the recommended update.';

        List<RecordActionAction.Response> actionResponses =
            RecordActionAction.invoke(new List<RecordActionAction.Request>{ actionReq });

        System.assertEquals(1, actionResponses.size());
        System.assertEquals(true, actionResponses[0].success);
        System.assertEquals(2, actionResponses[0].sequenceNumber);
        System.assertEquals(64, actionResponses[0].recordHash.length());

        SealSessionAction.Request sealReq = new SealSessionAction.Request();
        sealReq.sessionId = startResponses[0].sessionId;

        List<SealSessionAction.Response> sealResponses =
            SealSessionAction.invoke(new List<SealSessionAction.Request>{ sealReq });

        System.assertEquals(1, sealResponses.size());
        System.assertEquals(true, sealResponses[0].success);
        System.assertEquals(startResponses[0].sessionId, sealResponses[0].sessionId);
        System.assertEquals(2, sealResponses[0].recordCount);
        System.assertEquals(64, sealResponses[0].merkleRoot.length());

        VerifySessionAction.Request verifyReq = new VerifySessionAction.Request();
        verifyReq.sessionId = startResponses[0].sessionId;

        List<VerifySessionAction.Response> verifyResponses =
            VerifySessionAction.invoke(new List<VerifySessionAction.Request>{ verifyReq });

        System.assertEquals(1, verifyResponses.size());
        System.assertEquals(true, verifyResponses[0].verified);
        System.assertEquals('Verified', verifyResponses[0].verificationStatus);
        System.assertEquals(2, verifyResponses[0].recordCount);
        System.assertEquals(64, verifyResponses[0].merkleRoot.length());
    }

    @IsTest
    static void testStartSessionInvocableValidation() {
        StartSessionAction.Request startReq = new StartSessionAction.Request();

        List<StartSessionAction.Response> responses =
            StartSessionAction.invoke(new List<StartSessionAction.Request>{ startReq });

        System.assertEquals(1, responses.size());
        System.assertEquals(false, responses[0].success);
        System.assertEquals('agentName is required.', responses[0].errorMessage);
    }

    @IsTest
    static void testRecordDecisionValidation() {
        RecordDecisionAction.Request req = new RecordDecisionAction.Request();
        req.actionLabel = 'Missing Session';

        List<RecordDecisionAction.Response> responses =
            RecordDecisionAction.invoke(new List<RecordDecisionAction.Request>{ req });

        System.assertEquals(1, responses.size());
        System.assertEquals(false, responses[0].success);
        System.assertEquals('sessionId is required.', responses[0].errorMessage);
    }
}
