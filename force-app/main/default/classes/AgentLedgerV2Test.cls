/**
 * AgentLedgerV2Test
 *
 * Phase 1 fixes: v2 hashing of new runs, verification independent of the
 * verifier's time zone, legacy v1 runs verified in their creator's time zone,
 * sealing only active runs, and 18-character record Ids.
 */
@isTest
private class AgentLedgerV2Test {

    private static final String RELATED_ID = '500000000000001';
    private static final String OTHER_TZ = 'Asia/Kolkata';

    private static User userInTimeZone(String timeZoneSidKey) {
        User me = [SELECT ProfileId, LocaleSidKey, LanguageLocaleKey, EmailEncodingKey FROM User WHERE Id = :UserInfo.getUserId()];
        String unique = String.valueOf(Crypto.getRandomInteger()).replace('-', '') + DateTime.now().getTime();
        User u = new User(
            ProfileId = me.ProfileId,
            Username = 'agentledger.tz.' + unique + '@example.com',
            Email = 'agentledger.tz@example.com',
            LastName = 'TZ',
            Alias = 'altz',
            TimeZoneSidKey = timeZoneSidKey,
            LocaleSidKey = me.LocaleSidKey,
            LanguageLocaleKey = me.LanguageLocaleKey,
            EmailEncodingKey = me.EmailEncodingKey
        );
        insert u;
        return u;
    }

    private static Id sealedRun() {
        Id sessionId = AgentAuditRecorder.startSession('case-escalation-agent', RELATED_ID, 'agentforce');
        AgentAuditRecorder.recordAction(sessionId, 'case-escalation-agent', 'Query', 'Priority High', 'Loaded', 'Looked up the Case');
        AgentAuditRecorder.recordAction(sessionId, 'case-escalation-agent', 'Decision', 'High, New', 'Escalate', 'Meets the criteria');
        AgentAuditRecorder.recordAction(sessionId, 'case-escalation-agent', 'Update', 'Status', 'Escalated', 'Escalated the Case');
        AgentAuditRecorder.sealSession(sessionId);
        return sessionId;
    }

    @isTest
    static void newRunsUseV2AndStoreTheExactTimestamp() {
        Id sessionId = sealedRun();
        Agent_Audit_Session__c s = [SELECT Hash_Version__c, Merkle_Root__c FROM Agent_Audit_Session__c WHERE Id = :sessionId];
        System.assertEquals('v2', s.Hash_Version__c);

        List<String> hashes = new List<String>();
        for (Agent_Audit_Record__c r : [SELECT Entry_Id__c, Timestamp_Text__c, Record_Hash__c, Capture_Method__c
                                        FROM Agent_Audit_Record__c WHERE Audit_Session__c = :sessionId ORDER BY Sequence_Number__c]) {
            System.assert(Pattern.matches('\\d{4}-\\d{2}-\\d{2}T\\d{2}:\\d{2}:\\d{2}\\.\\d{3}Z', r.Timestamp_Text__c), r.Timestamp_Text__c);
            System.assertEquals(36, r.Entry_Id__c.length());
            System.assertEquals('Reported_by_Agent', r.Capture_Method__c);
            hashes.add(r.Record_Hash__c);
        }
        System.assertEquals(MerkleTreeService.computeMerkleRootV2(hashes), s.Merkle_Root__c, 'sealed with the v2 root');
        System.assert(AgentAuditRecorder.verifySession(sessionId).valid);
    }

    @isTest
    static void verificationDoesNotDependOnTheVerifiersTimeZone() {
        Id sessionId = sealedRun();
        User elsewhere = userInTimeZone(OTHER_TZ);
        AgentAuditRecorder.VerifySessionResult result;
        Test.startTest();
        System.runAs(elsewhere) {
            result = AgentAuditRecorder.verifySession(sessionId);
        }
        Test.stopTest();
        System.assert(result.valid, 'A genuine run verifies from another time zone: ' + result.message);
    }

    @isTest
    static void legacyV1RunsVerifyInTheirCreatorsTimeZone() {
        // A run as recorded before v2: no hash version, v1 hashes in the recorder's time zone.
        Agent_Audit_Session__c session = new Agent_Audit_Session__c(
            Session_Id__c = 'legacy-0001', Agent_Id__c = 'legacy-agent', Status__c = 'Active',
            Start_Time__c = DateTime.now(), Related_Record_Id__c = String.valueOf(Id.valueOf(RELATED_ID)), Record_Count__c = 0);
        insert session;
        AgentAuditRecorder.recordAction(session.Id, 'legacy-agent', 'Query', 'in', 'out', 'v1 entry one');
        AgentAuditRecorder.recordAction(session.Id, 'legacy-agent', 'Decision', 'in', 'out', 'v1 entry two');
        AgentAuditRecorder.sealSession(session.Id);

        Agent_Audit_Record__c first = [SELECT Id, Name, Audit_Session__c, Sequence_Number__c, Action_Timestamp__c, Agent_Id__c,
                                       Action_Type__c, Input_Context__c, Output_Result__c, Reasoning__c, Previous_Hash__c, Record_Hash__c
                                       FROM Agent_Audit_Record__c WHERE Audit_Session__c = :session.Id AND Sequence_Number__c = 0];
        System.assertEquals(HashChainService.hashActionRecord(first, UserInfo.getTimeZone().getID()), first.Record_Hash__c,
            'legacy run keeps v1 hashing');

        User elsewhere = userInTimeZone(OTHER_TZ);
        AgentAuditRecorder.VerifySessionResult result;
        Test.startTest();
        System.runAs(elsewhere) {
            result = AgentAuditRecorder.verifySession(session.Id);
        }
        Test.stopTest();
        System.assert(result.valid, 'A v1 run verifies from another time zone: ' + result.message);
    }

    @isTest
    static void v2CoversTheNewFieldsAndDetectsChanges() {
        Id sessionId = AgentAuditRecorder.startSession('case-escalation-agent', RELATED_ID, 'agentforce');
        AgentAuditRecorder.EntryInput entry = new AgentAuditRecorder.EntryInput();
        entry.agentId = 'case-escalation-agent';
        entry.actionType = 'Data_Change';
        entry.reasoning = 'Escalated the Case';
        entry.summary = 'Set Status to Escalated';
        entry.targetRecordId = RELATED_ID;
        entry.targetObject = 'Case';
        entry.fieldChanges = '[{"field":"Status","before":"New","after":"Escalated"}]';
        entry.captureMethod = 'Recorded_Action';
        entry.turnNumber = 2;
        Agent_Audit_Record__c rec = AgentAuditRecorder.recordEntry(sessionId, entry);
        AgentAuditRecorder.sealSession(sessionId);

        rec = [SELECT Target_Record_Id__c FROM Agent_Audit_Record__c WHERE Id = :rec.Id];
        System.assertEquals(18, rec.Target_Record_Id__c.length(), 'target Id stored as 18 characters');
        System.assert(AgentAuditRecorder.verifySession(sessionId).valid);

        AgentLedgerGuard.allowManualEditsForTest = true; // simulate tampering for the test
        update new Agent_Audit_Record__c(Id = rec.Id, Field_Changes__c = '[{"field":"Status","before":"New","after":"Closed"}]');
        AgentAuditRecorder.VerifySessionResult result = AgentAuditRecorder.verifySession(sessionId);
        System.assert(!result.valid, 'a changed field change is detected');
        System.assertEquals('Tampered', [SELECT Integrity__c FROM Agent_Audit_Session__c WHERE Id = :sessionId].Integrity__c);
    }

    @isTest
    static void onlyAnActiveRunCanBeSealed() {
        Id sessionId = sealedRun();
        Agent_Audit_Record__c first = [SELECT Id FROM Agent_Audit_Record__c WHERE Audit_Session__c = :sessionId AND Sequence_Number__c = 0];
        AgentLedgerGuard.allowManualEditsForTest = true; // simulate tampering for the test
        update new Agent_Audit_Record__c(Id = first.Id, Reasoning__c = 'rewritten');
        System.assert(!AgentAuditRecorder.verifySession(sessionId).valid);

        // Sealing again must not recompute the root over the rewritten entry.
        try {
            AgentAuditRecorder.sealSession(sessionId);
            System.assert(false, 'sealing a closed run should fail');
        } catch (MerkleTreeService.AgentLedgerException e) {
            System.assert(e.getMessage().contains('Only an active session can be sealed'), e.getMessage());
        }
        System.assertEquals('Tampered', [SELECT Integrity__c FROM Agent_Audit_Session__c WHERE Id = :sessionId].Integrity__c);
    }

    @isTest
    static void recordIdsAreNormalized() {
        System.assertEquals(String.valueOf(Id.valueOf(RELATED_ID)), AgentAuditRecorder.normalizeId(RELATED_ID));
        System.assertEquals(String.valueOf(Id.valueOf(RELATED_ID)), AgentAuditRecorder.normalizeId(' ' + String.valueOf(Id.valueOf(RELATED_ID)) + ' '));
        System.assertEquals(null, AgentAuditRecorder.normalizeId(''));
        try {
            AgentAuditRecorder.normalizeId('00001026');
            System.assert(false, 'a case number is not an Id');
        } catch (MerkleTreeService.AgentLedgerException e) {
            System.assert(e.getMessage().contains('Not a valid Salesforce record Id'));
        }
    }

    @isTest
    static void theRecordPageFindsRunsByEitherIdForm() {
        sealedRun();
        System.assertEquals(1, RecordAuditTrailController.getSessionsForRecord(RELATED_ID).size(), '15-character form');
        System.assertEquals(1, RecordAuditTrailController.getSessionsForRecord(String.valueOf(Id.valueOf(RELATED_ID))).size(), '18-character form');
    }

    @isTest
    static void v2ProofsVerifyForEverySize() {
        List<String> hashes = new List<String>();
        for (Integer n = 1; n <= 7; n++) {
            hashes.add(HashChainService.sha256('record-' + n));
            String root = MerkleTreeService.computeMerkleRootV2(hashes);
            for (Integer i = 0; i < n; i++) {
                MerkleTreeService.MerkleProof proof = MerkleTreeService.generateProofV2(hashes, i);
                System.assertEquals(root, proof.root);
                System.assert(MerkleTreeService.verifyProofV2(proof), 'size ' + n + ' index ' + i);
            }
        }
        MerkleTreeService.MerkleProof proof = MerkleTreeService.generateProofV2(hashes, 3);
        proof.recordHash = hashes[4];
        System.assert(!MerkleTreeService.verifyProofV2(proof), 'a proof for another record fails');
        System.assertEquals(null, MerkleTreeService.generateProofV2(hashes, 7));
    }

    @isTest
    static void canonicalJsonEscapesLikeJavaScript() {
        System.assertEquals('{"a":[1,true,null],"b":"x\\"y\\\\z\\n\\u0001"}',
            AgentLedgerCanonical.serialize(new Map<String, Object>{
                'b' => 'x"y\\z\n' + String.fromCharArray(new List<Integer>{ 1 }),
                'a' => new List<Object>{ 1, true, null }
            }));
        try {
            AgentLedgerCanonical.serialize(1.5);
            System.assert(false, 'decimals are rejected');
        } catch (AgentLedgerCanonical.CanonicalException e) {
            System.assert(e.getMessage().contains('unsupported'));
        }
    }
}
