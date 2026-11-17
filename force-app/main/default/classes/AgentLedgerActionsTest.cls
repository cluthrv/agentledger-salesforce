/**
 * AgentLedgerActionsTest
 *
 * The Record Agent Action and Seal AgentLedger Session actions, the full
 * record -> seal -> verify lifecycle, HashChainService (broken-chain
 * detection) and MerkleTreeService (root edge cases). Runs start
 * automatically; here they are started through AgentAuditRecorder.
 */
@isTest
private class AgentLedgerActionsTest {

    // ── Helper: start a run and return its Id ──
    private static Id startViaAction(String agentId, String relatedRecordId) {
        Id sessionId = AgentAuditRecorder.startSession(agentId, relatedRecordId, 'salesforce');
        System.assertNotEquals(null, sessionId);
        return sessionId;
    }

    // ════════════════════════════════════════════════════════════
    // RecordAgentActionAction
    // ════════════════════════════════════════════════════════════

    @isTest
    static void testRecordSuccess() {
        Id sessionId = startViaAction('agent-1', '006000000000002');

        RecordAgentActionAction.Request req = new RecordAgentActionAction.Request();
        req.sessionId = sessionId;
        req.agentId = 'agent-1';
        req.actionType = 'Query';
        req.inputContext = '{"field":"Amount"}';
        req.outputResult = '{"amount":275000}';
        req.reasoning = 'Retrieved the Opportunity amount for qualification.';

        List<RecordAgentActionAction.Result> results =
            RecordAgentActionAction.execute(
                new List<RecordAgentActionAction.Request>{ req });

        System.assert(results[0].success, 'Record failed: ' + results[0].errorMessage);
        System.assertNotEquals(null, results[0].auditRecordId);
        System.assertNotEquals(null, results[0].recordHash);
        System.assertEquals(0, results[0].sequenceNumber);
    }

    @isTest
    static void testRecordInvalidActionType() {
        Id sessionId = startViaAction('agent-1', '006000000000003');

        RecordAgentActionAction.Request req = new RecordAgentActionAction.Request();
        req.sessionId = sessionId;
        req.agentId = 'agent-1';
        req.actionType = 'NotARealType';
        req.reasoning = 'x';

        List<RecordAgentActionAction.Result> results =
            RecordAgentActionAction.execute(
                new List<RecordAgentActionAction.Request>{ req });

        System.assertEquals(false, results[0].success);
        System.assertNotEquals(null, results[0].errorMessage);
    }

    @isTest
    static void testRecordMissingSessionId() {
        // Without a Session Id, the agent's open run is used or a new one is started.
        RecordAgentActionAction.Request req = new RecordAgentActionAction.Request();
        req.sessionId = null;
        req.agentId = 'agent-1';
        req.actionType = 'Query';
        req.reasoning = 'x';

        List<RecordAgentActionAction.Result> results =
            RecordAgentActionAction.execute(
                new List<RecordAgentActionAction.Request>{ req, req });

        System.assert(results[0].success, results[0].errorMessage);
        System.assert(results[1].success, results[1].errorMessage);
        System.assertEquals(1, [SELECT COUNT() FROM Agent_Audit_Session__c], 'both steps go into one run');
        System.assertEquals(1, results[1].sequenceNumber);
    }

    @isTest
    static void testRecordMissingReasoning() {
        Id sessionId = startViaAction('agent-1', '006000000000004');

        RecordAgentActionAction.Request req = new RecordAgentActionAction.Request();
        req.sessionId = sessionId;
        req.agentId = 'agent-1';
        req.actionType = 'Decision';
        req.reasoning = '';

        List<RecordAgentActionAction.Result> results =
            RecordAgentActionAction.execute(
                new List<RecordAgentActionAction.Request>{ req });

        System.assertEquals(false, results[0].success);
    }

    @isTest
    static void testRecordMissingAgentId() {
        Id sessionId = startViaAction('agent-1', '006000000000012');

        RecordAgentActionAction.Request req = new RecordAgentActionAction.Request();
        req.sessionId = sessionId;
        req.agentId = '';
        req.actionType = 'Query';
        req.reasoning = 'Missing agent id.';

        List<RecordAgentActionAction.Result> results =
            RecordAgentActionAction.execute(
                new List<RecordAgentActionAction.Request>{ req });

        System.assertEquals(false, results[0].success);
    }

    // ════════════════════════════════════════════════════════════
    // SealAgentLedgerSessionAction
    // ════════════════════════════════════════════════════════════

    @isTest
    static void testSealSuccess() {
        Id sessionId = startViaAction('agent-2', '006000000000005');

        RecordAgentActionAction.Request rec = new RecordAgentActionAction.Request();
        rec.sessionId = sessionId;
        rec.agentId = 'agent-2';
        rec.actionType = 'Query';
        rec.reasoning = 'Recorded a step before sealing.';
        RecordAgentActionAction.execute(
            new List<RecordAgentActionAction.Request>{ rec });

        Test.startTest();
        SealAgentLedgerSessionAction.Request seal =
            new SealAgentLedgerSessionAction.Request();
        seal.sessionId = sessionId;
        List<SealAgentLedgerSessionAction.Result> results =
            SealAgentLedgerSessionAction.execute(
                new List<SealAgentLedgerSessionAction.Request>{ seal });
        Test.stopTest();

        System.assert(results[0].success, 'Seal failed: ' + results[0].errorMessage);
        System.assertNotEquals(null, results[0].merkleRoot);
        System.assertEquals(64, results[0].merkleRoot.length());
    }

    @isTest
    static void testSealMissingSessionId() {
        SealAgentLedgerSessionAction.Request seal =
            new SealAgentLedgerSessionAction.Request();
        seal.sessionId = null;

        List<SealAgentLedgerSessionAction.Result> results =
            SealAgentLedgerSessionAction.execute(
                new List<SealAgentLedgerSessionAction.Request>{ seal });

        System.assertEquals(true, results[0].success, 'no run to close is not an error');
        System.assertEquals(null, results[0].merkleRoot);
    }

    // ════════════════════════════════════════════════════════════
    // Full lifecycle through the action layer
    // ════════════════════════════════════════════════════════════

    @isTest
    static void testFullLifecycleThroughActions() {
        Id sessionId = startViaAction('lifecycle-agent', '006000000000007');

        for (String t : new List<String>{ 'Query', 'Validation', 'Decision' }) {
            RecordAgentActionAction.Request rec =
                new RecordAgentActionAction.Request();
            rec.sessionId = sessionId;
            rec.agentId = 'lifecycle-agent';
            rec.actionType = t;
            rec.inputContext = '{"step":"' + t + '"}';
            rec.outputResult = '{"ok":true}';
            rec.reasoning = 'Step for ' + t;
            List<RecordAgentActionAction.Result> recRes =
                RecordAgentActionAction.execute(
                    new List<RecordAgentActionAction.Request>{ rec });
            System.assert(recRes[0].success, 'Rec failed: ' + recRes[0].errorMessage);
        }

        SealAgentLedgerSessionAction.Request seal =
            new SealAgentLedgerSessionAction.Request();
        seal.sessionId = sessionId;
        List<SealAgentLedgerSessionAction.Result> sealRes =
            SealAgentLedgerSessionAction.execute(
                new List<SealAgentLedgerSessionAction.Request>{ seal });
        System.assert(sealRes[0].success, 'Seal failed: ' + sealRes[0].errorMessage);

        AgentAuditRecorder.VerifySessionResult verRes = AgentAuditRecorder.verifySession(sessionId);
        System.assert(verRes.valid, 'Verify failed: ' + verRes.message);

        Agent_Audit_Session__c s = [
            SELECT Status__c, Record_Count__c
            FROM Agent_Audit_Session__c WHERE Id = :sessionId
        ];
        System.assertEquals(3, s.Record_Count__c);
    }

    // ════════════════════════════════════════════════════════════
    // HashChainService coverage
    // ════════════════════════════════════════════════════════════

    @isTest
    static void testHashActionRecordOverload() {
        Agent_Audit_Record__c rec = new Agent_Audit_Record__c(
            Sequence_Number__c = 0,
            Action_Timestamp__c = DateTime.now(),
            Agent_Id__c = 'agent-x',
            Action_Type__c = 'Query',
            Input_Context__c = '{"a":1}',
            Output_Result__c = '{"b":2}',
            Reasoning__c = 'test reasoning',
            Previous_Hash__c = ''
        );
        String h = HashChainService.hashActionRecord(rec);
        System.assertEquals(64, h.length(), 'Hash should be 64 hex chars');
    }

    @isTest
    static void testVerifyChainDetectsTamperedHash() {
        Id sessionId = startViaAction('chain-agent', '006000000000010');

        RecordAgentActionAction.Request rec = new RecordAgentActionAction.Request();
        rec.sessionId = sessionId;
        rec.agentId = 'chain-agent';
        rec.actionType = 'Query';
        rec.reasoning = 'first record';
        RecordAgentActionAction.execute(
            new List<RecordAgentActionAction.Request>{ rec });

        Agent_Audit_Record__c stored = [
            SELECT Id, Record_Hash__c FROM Agent_Audit_Record__c
            WHERE Audit_Session__c = :sessionId LIMIT 1
        ];
        stored.Record_Hash__c = 'deadbeef' + '0'.repeat(56);
        AgentLedgerGuard.allowManualEditsForTest = true; // simulate tampering for the test
        update stored;

        List<Agent_Audit_Record__c> records = [
            SELECT Id, Name, Audit_Session__c, Sequence_Number__c, Action_Timestamp__c,
                   Agent_Id__c, Action_Type__c, Input_Context__c, Output_Result__c,
                   Reasoning__c, Previous_Hash__c, Record_Hash__c
            FROM Agent_Audit_Record__c WHERE Audit_Session__c = :sessionId
            ORDER BY Sequence_Number__c ASC
        ];
        HashChainService.VerificationResult result =
            HashChainService.verifyChain(records);
        System.assertEquals(false, result.valid, 'Tampered hash should fail');
        System.assertNotEquals(null, result.errors);
    }

    @isTest
    static void testVerifyChainDetectsBrokenLink() {
        Id sessionId = startViaAction('chain-agent2', '006000000000011');

        for (Integer i = 0; i < 2; i++) {
            RecordAgentActionAction.Request rec = new RecordAgentActionAction.Request();
            rec.sessionId = sessionId;
            rec.agentId = 'chain-agent2';
            rec.actionType = 'Query';
            rec.reasoning = 'record ' + i;
            RecordAgentActionAction.execute(
                new List<RecordAgentActionAction.Request>{ rec });
        }

        List<Agent_Audit_Record__c> recs = [
            SELECT Id, Sequence_Number__c, Previous_Hash__c
            FROM Agent_Audit_Record__c WHERE Audit_Session__c = :sessionId
            ORDER BY Sequence_Number__c ASC
        ];
        recs[1].Previous_Hash__c = 'wronghash' + '0'.repeat(55);
        AgentLedgerGuard.allowManualEditsForTest = true; // simulate tampering for the test
        update recs[1];

        List<Agent_Audit_Record__c> records = [
            SELECT Id, Name, Audit_Session__c, Sequence_Number__c, Action_Timestamp__c,
                   Agent_Id__c, Action_Type__c, Input_Context__c, Output_Result__c,
                   Reasoning__c, Previous_Hash__c, Record_Hash__c
            FROM Agent_Audit_Record__c WHERE Audit_Session__c = :sessionId
            ORDER BY Sequence_Number__c ASC
        ];
        HashChainService.VerificationResult result =
            HashChainService.verifyChain(records);
        System.assertEquals(false, result.valid, 'Broken link should fail');
    }

    @isTest
    static void testVerifyChainEmpty() {
        HashChainService.VerificationResult result =
            HashChainService.verifyChain(new List<Agent_Audit_Record__c>());
        System.assertEquals(true, result.valid, 'Empty chain should be valid');
    }

    // ════════════════════════════════════════════════════════════
    // MerkleTreeService coverage
    // ════════════════════════════════════════════════════════════

    @isTest
    static void testComputeMerkleRootSingleLeaf() {
        String root = MerkleTreeService.computeMerkleRoot(
            new List<String>{ 'a'.repeat(64) });
        System.assertEquals(64, root.length());
    }

    @isTest
    static void testComputeMerkleRootOddLeaves() {
        String root = MerkleTreeService.computeMerkleRoot(new List<String>{
            'a'.repeat(64), 'b'.repeat(64), 'c'.repeat(64)
        });
        System.assertEquals(64, root.length());
    }

    @isTest
    static void testComputeMerkleRootEmpty() {
        String root = MerkleTreeService.computeMerkleRoot(new List<String>());
        System.assertEquals(null, root, 'Empty list returns null root');
    }
}