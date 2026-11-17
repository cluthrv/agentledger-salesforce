/**
 * AgentLedgerTest
 *
 * Comprehensive test suite for HashChainService, MerkleTreeService,
 * and AgentAuditRecorder. Covers hash computation, chain verification,
 * Merkle tree operations, session lifecycle, and tamper detection.
 */
@isTest
private class AgentLedgerTest {

    private static final String RELATED_ID = '006000000000001';

    // ── HashChainService Tests ──

    @isTest
    static void testSha256ProducesValidHash() {
        String hash = HashChainService.sha256('hello');
        System.assertEquals(64, hash.length(), 'SHA-256 should produce 64-char hex string');
        System.assert(hash.isAlphanumeric(), 'Hash should be alphanumeric hex');
    }

    @isTest
    static void testSha256IsDeterministic() {
        String hash1 = HashChainService.sha256('test-data');
        String hash2 = HashChainService.sha256('test-data');
        System.assertEquals(hash1, hash2, 'Same input should produce same hash');
    }

    @isTest
    static void testSha256DifferentInputsDifferentHashes() {
        String hash1 = HashChainService.sha256('input-a');
        String hash2 = HashChainService.sha256('input-b');
        System.assertNotEquals(hash1, hash2, 'Different inputs should produce different hashes');
    }

    @isTest
    static void testCombineHashesIsOrderDependent() {
        String ab = HashChainService.combineHashes('hash-a', 'hash-b');
        String ba = HashChainService.combineHashes('hash-b', 'hash-a');
        System.assertNotEquals(ab, ba, 'Hash combination should be order-dependent');
    }

    // ── MerkleTreeService Tests ──

    @isTest
    static void testMerkleRootEmptyInput() {
        String root = MerkleTreeService.computeMerkleRoot(new List<String>());
        System.assertEquals(null, root, 'Empty input should return null');
    }

    @isTest
    static void testMerkleRootSingleHash() {
        String root = MerkleTreeService.computeMerkleRoot(new List<String>{'hash-a'});
        System.assertNotEquals(null, root, 'Single hash should produce a root');
        System.assertEquals(64, root.length(), 'Root should be 64-char hex');
    }

    @isTest
    static void testMerkleRootIsDeterministic() {
        List<String> hashes = new List<String>{'aaa', 'bbb', 'ccc', 'ddd'};
        String root1 = MerkleTreeService.computeMerkleRoot(hashes);
        String root2 = MerkleTreeService.computeMerkleRoot(hashes);
        System.assertEquals(root1, root2, 'Same hashes should produce same root');
    }

    @isTest
    static void testMerkleRootChangesWithDifferentInput() {
        String root1 = MerkleTreeService.computeMerkleRoot(new List<String>{'a', 'b', 'c'});
        String root2 = MerkleTreeService.computeMerkleRoot(new List<String>{'a', 'b', 'd'});
        System.assertNotEquals(root1, root2, 'Different hashes should produce different roots');
    }

    @isTest
    static void testMerkleRootIsOrderSensitive() {
        String root1 = MerkleTreeService.computeMerkleRoot(new List<String>{'a', 'b', 'c'});
        String root2 = MerkleTreeService.computeMerkleRoot(new List<String>{'c', 'b', 'a'});
        System.assertNotEquals(root1, root2, 'Different order should produce different roots');
    }

    // ── AgentAuditRecorder Integration Tests ──

   @isTest
    static void testStartSession() {
        Id sessionId = AgentAuditRecorder.startSession(
            'test-agent', '006000000000001', 'salesforce'
        );

        Agent_Audit_Session__c session = [
            SELECT Agent_Id__c, Status__c, Related_Record_Id__c, Platform__c
            FROM Agent_Audit_Session__c
            WHERE Id = :sessionId
        ];

        System.assertEquals('test-agent', session.Agent_Id__c);
        System.assertEquals('Active', session.Status__c);
        System.assertEquals(String.valueOf(Id.valueOf('006000000000001')), session.Related_Record_Id__c,
            'Related record Id is stored as 18 characters');
        System.assertEquals(18, session.Related_Record_Id__c.length());
        System.assertEquals('salesforce', session.Platform__c);
    }

    @isTest
    static void testRecordAction() {
        Id sessionId = AgentAuditRecorder.startSession('test-agent', RELATED_ID, 'salesforce');

        Agent_Audit_Record__c record = AgentAuditRecorder.recordAction(
            sessionId, 'test-agent', 'Query',
            '{"query":"get price"}', '{"price":100}',
            'Retrieved base price'
        );

        System.assertNotEquals(null, record.Id);
        System.assertEquals(0, record.Sequence_Number__c);
        System.assertEquals('Query', record.Action_Type__c);
        System.assertNotEquals(null, record.Record_Hash__c);
        System.assertEquals(null, record.Previous_Hash__c);
    }

    @isTest
    static void testRecordChaining() {
        Id sessionId = AgentAuditRecorder.startSession('test-agent', RELATED_ID, 'salesforce');

        Agent_Audit_Record__c r1 = AgentAuditRecorder.recordAction(
            sessionId, 'test-agent', 'Query',
            '{"q":"first"}', '{"r":"first"}', 'First action'
        );

        Agent_Audit_Record__c r2 = AgentAuditRecorder.recordAction(
            sessionId, 'test-agent', 'Calculation',
            '{"q":"second"}', '{"r":"second"}', 'Second action'
        );

        // Reload r2 to get the Previous_Hash__c
        r2 = [SELECT Previous_Hash__c, Record_Hash__c, Sequence_Number__c
              FROM Agent_Audit_Record__c WHERE Id = :r2.Id];

        System.assertEquals(1, r2.Sequence_Number__c);
        System.assertEquals(r1.Record_Hash__c, r2.Previous_Hash__c,
            'Second record should chain to first record hash');
    }

    @isTest
    static void testSealSession() {
        Id sessionId = AgentAuditRecorder.startSession('test-agent', RELATED_ID, 'salesforce');

        AgentAuditRecorder.recordAction(sessionId, 'test-agent', 'Query',
            '{"q":"test"}', '{"r":"test"}', 'Test action 1');
        AgentAuditRecorder.recordAction(sessionId, 'test-agent', 'Create',
            '{"q":"test2"}', '{"r":"test2"}', 'Test action 2');

        String merkleRoot = AgentAuditRecorder.sealSession(sessionId);

        System.assertNotEquals(null, merkleRoot);
        System.assertEquals(64, merkleRoot.length());

        Agent_Audit_Session__c session = [
            SELECT Status__c, Merkle_Root__c, Record_Count__c
            FROM Agent_Audit_Session__c WHERE Id = :sessionId
        ];

        System.assertEquals('Closed', session.Status__c);
        System.assertEquals(merkleRoot, session.Merkle_Root__c);
        System.assertEquals(2, session.Record_Count__c);
    }

    @isTest
    static void testSealEmptySessionThrows() {
        Id sessionId = AgentAuditRecorder.startSession('test-agent', RELATED_ID, 'salesforce');

        try {
            AgentAuditRecorder.sealSession(sessionId);
            System.assert(false, 'Should have thrown exception');
        } catch (MerkleTreeService.AgentLedgerException e) {
            System.assert(e.getMessage().contains('empty session'));
        }
    }

    @isTest
    static void testRecordAfterSealThrows() {
        Id sessionId = AgentAuditRecorder.startSession('test-agent', RELATED_ID, 'salesforce');
        AgentAuditRecorder.recordAction(sessionId, 'test-agent', 'Query',
            '{"q":"test"}', '{"r":"test"}', 'Action');
        AgentAuditRecorder.sealSession(sessionId);

        try {
            AgentAuditRecorder.recordAction(sessionId, 'test-agent', 'Query',
                '{"q":"post-seal"}', '{"r":"blocked"}', 'Should fail');
            System.assert(false, 'Should have thrown exception');
        } catch (MerkleTreeService.AgentLedgerException e) {
            System.assert(e.getMessage().contains('Closed'), e.getMessage());
        }
    }

    @isTest
    static void testVerifySession() {
        Id sessionId = AgentAuditRecorder.startSession('test-agent', RELATED_ID, 'salesforce');

        AgentAuditRecorder.recordAction(sessionId, 'test-agent', 'Query',
            '{"q":"1"}', '{"r":"1"}', 'Action 1');
        AgentAuditRecorder.recordAction(sessionId, 'test-agent', 'Calculation',
            '{"q":"2"}', '{"r":"2"}', 'Action 2');
        AgentAuditRecorder.recordAction(sessionId, 'test-agent', 'Create',
            '{"q":"3"}', '{"r":"3"}', 'Action 3');

        AgentAuditRecorder.sealSession(sessionId);

        AgentAuditRecorder.VerifySessionResult result =
            AgentAuditRecorder.verifySession(sessionId);

        System.assert(result.valid, 'Sealed session should verify: ' + result.message);

        for (AgentAuditRecorder.VerificationCheck check : result.checks) {
            System.assert(check.passed, check.name + ' failed: ' + check.detail);
        }
    }

    /** A sealed run with seven entries, the shape the old runDemo produced. */
    private static Id sealedSevenEntryRun() {
        Id sessionId = AgentAuditRecorder.startSession('cpq-pricing-agent', RELATED_ID, 'salesforce');
        for (Integer i = 0; i < 7; i++) {
            AgentAuditRecorder.recordAction(sessionId, 'cpq-pricing-agent', i == 6 ? 'Create' : 'Query',
                '{"step":' + i + '}', '{"ok":true}', 'Step ' + i);
        }
        AgentAuditRecorder.sealSession(sessionId);
        return sessionId;
    }

    @isTest
    static void testSealedSevenEntryRun() {
        Id sessionId = sealedSevenEntryRun();

        Agent_Audit_Session__c session = [
            SELECT Status__c, Merkle_Root__c, Record_Count__c
            FROM Agent_Audit_Session__c WHERE Id = :sessionId
        ];

        System.assertEquals('Closed', session.Status__c);
        System.assertEquals(7, session.Record_Count__c);
        System.assertNotEquals(null, session.Merkle_Root__c);
    }
}
