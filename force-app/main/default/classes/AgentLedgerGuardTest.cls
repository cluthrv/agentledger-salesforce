/**
 * AgentLedgerGuardTest
 *
 * Phase 1 step 2: the ledger is append-only, run status is the lifecycle, and
 * verification is recorded as Integrity with Last Verified At.
 */
@isTest
private class AgentLedgerGuardTest {

    private static final String CASE_ID = '500000000000001';

    private static Id closedRun() {
        Id sessionId = AgentAuditRecorder.startSession('case-escalation-agent', CASE_ID, 'agentforce');
        AgentAuditRecorder.recordAction(sessionId, 'case-escalation-agent', 'Query', 'in', 'out', 'Looked up the Case');
        AgentAuditRecorder.recordAction(sessionId, 'case-escalation-agent', 'Decision', 'in', 'Escalate', 'Meets the criteria');
        AgentAuditRecorder.sealSession(sessionId);
        return sessionId;
    }

    /**
     * A user without the testing permission, whoever runs the tests: the
     * running user may hold AgentLedger Tamper Testing.
     */
    private static User plainUser() {
        User me = [SELECT ProfileId, LocaleSidKey, LanguageLocaleKey, EmailEncodingKey, TimeZoneSidKey FROM User WHERE Id = :UserInfo.getUserId()];
        User u = new User(
            ProfileId = me.ProfileId,
            Username = 'agentledger.guard.' + Crypto.getRandomInteger() + DateTime.now().getTime() + '@example.com',
            Email = 'agentledger.guard@example.com', LastName = 'Guard', Alias = 'alguard',
            TimeZoneSidKey = me.TimeZoneSidKey, LocaleSidKey = me.LocaleSidKey,
            LanguageLocaleKey = me.LanguageLocaleKey, EmailEncodingKey = me.EmailEncodingKey);
        insert u;
        return u;
    }

    private static Agent_Audit_Session__c load(Id sessionId) {
        return [SELECT Status__c, Integrity__c, Last_Verified_At__c, Started_By__c, Related_Object__c, Initiator__c
                FROM Agent_Audit_Session__c WHERE Id = :sessionId];
    }

    @isTest
    static void entriesCannotBeEditedOrDeleted() {
        Id sessionId = closedRun();
        Agent_Audit_Record__c entry = [SELECT Id FROM Agent_Audit_Record__c WHERE Audit_Session__c = :sessionId LIMIT 1];

        System.runAs(plainUser()) {
            System.assert(!AgentLedgerGuard.manualEditsAllowed());
            Database.SaveResult edited = Database.update(new Agent_Audit_Record__c(Id = entry.Id, Reasoning__c = 'rewritten'), false);
            System.assert(!edited.isSuccess(), 'editing an entry is blocked');
            System.assert(edited.getErrors()[0].getMessage().contains('cannot be edited'), edited.getErrors()[0].getMessage());

            Database.DeleteResult deleted = Database.delete(entry.Id, false);
            System.assert(!deleted.isSuccess(), 'deleting an entry is blocked');
        }
    }

    @isTest
    static void protectedRunFieldsCannotBeChangedButOthersCan() {
        Id sessionId = closedRun();

        System.runAs(plainUser()) {
            Database.SaveResult reopened = Database.update(new Agent_Audit_Session__c(Id = sessionId, Status__c = 'Active'), false);
            System.assert(!reopened.isSuccess(), 'reopening a closed run is blocked');

            Database.SaveResult forged = Database.update(new Agent_Audit_Session__c(Id = sessionId, Integrity__c = 'Verified'), false);
            System.assert(!forged.isSuccess(), 'setting the integrity result by hand is blocked');

            Database.SaveResult note = Database.update(new Agent_Audit_Session__c(Id = sessionId, Initiator__c = 'Support desk'), false);
            System.assert(note.isSuccess(), 'non-protected fields stay editable');

            Database.DeleteResult deleted = Database.delete(sessionId, false);
            System.assert(!deleted.isSuccess(), 'deleting a run is blocked');
        }
    }

    @isTest
    static void theTestingPermissionAllowsEditsAndVerificationStillCatchesThem() {
        Id sessionId = closedRun();
        Agent_Audit_Record__c entry = [SELECT Id, Reasoning__c FROM Agent_Audit_Record__c WHERE Audit_Session__c = :sessionId AND Sequence_Number__c = 1];

        AgentLedgerGuard.allowManualEditsForTest = true;
        update new Agent_Audit_Record__c(Id = entry.Id, Reasoning__c = 'rewritten');
        AgentLedgerGuard.allowManualEditsForTest = false;

        System.assert(!AgentAuditRecorder.verifySession(sessionId).valid);
        System.assertEquals('Tampered', load(sessionId).Integrity__c);
    }

    @isTest
    static void verificationRecordsTheResultWithItsTimeAndKeepsTheLifecycle() {
        Id sessionId = closedRun();
        Agent_Audit_Session__c before = load(sessionId);
        System.assertEquals('Closed', before.Status__c);
        System.assertEquals('Not_Checked', before.Integrity__c);
        System.assertEquals(null, before.Last_Verified_At__c);

        System.assert(AgentAuditRecorder.verifySession(sessionId).valid);
        Agent_Audit_Session__c verified = load(sessionId);
        System.assertEquals('Closed', verified.Status__c, 'status stays the lifecycle');
        System.assertEquals('Verified', verified.Integrity__c);
        System.assertNotEquals(null, verified.Last_Verified_At__c);

        // Tamper, then restore: the result follows the current content.
        Agent_Audit_Record__c entry = [SELECT Id, Reasoning__c FROM Agent_Audit_Record__c WHERE Audit_Session__c = :sessionId AND Sequence_Number__c = 0];
        String original = entry.Reasoning__c;
        AgentLedgerGuard.allowManualEditsForTest = true;
        update new Agent_Audit_Record__c(Id = entry.Id, Reasoning__c = 'rewritten');
        System.assert(!AgentAuditRecorder.verifySession(sessionId).valid);
        System.assertEquals('Tampered', load(sessionId).Integrity__c);
        update new Agent_Audit_Record__c(Id = entry.Id, Reasoning__c = original);
        AgentLedgerGuard.allowManualEditsForTest = false;
        System.assert(AgentAuditRecorder.verifySession(sessionId).valid);
        System.assertEquals('Verified', load(sessionId).Integrity__c);
    }

    @isTest
    static void runsWithAnEarlierStatusMoveToClosedWhenVerified() {
        Id sessionId = closedRun();
        AgentLedgerGuard.allowManualEditsForTest = true;
        update new Agent_Audit_Session__c(Id = sessionId, Status__c = 'Verified');
        AgentLedgerGuard.allowManualEditsForTest = false;

        System.assert(AgentAuditRecorder.verifySession(sessionId).valid, 'a run with an earlier status still verifies');
        Agent_Audit_Session__c after = load(sessionId);
        System.assertEquals('Closed', after.Status__c);
        System.assertEquals('Verified', after.Integrity__c);
    }

    @isTest
    static void newRunsRecordWhoStartedThemAndTheRelatedObject() {
        Id sessionId = AgentAuditRecorder.startSession('case-escalation-agent', CASE_ID, 'agentforce');
        Agent_Audit_Session__c run = load(sessionId);
        System.assertEquals(UserInfo.getUserId(), run.Started_By__c);
        System.assertEquals('Case', run.Related_Object__c);
        System.assertEquals('Active', run.Status__c);
    }

    @isTest
    static void theRecordPageShowsLifecycleAndIntegrity() {
        Id sessionId = closedRun();
        AgentAuditRecorder.verifySession(sessionId);
        AgentLedgerAccess.readAccessForTest = new Map<Id, Boolean>{ Id.valueOf(CASE_ID) => true }; // the viewer can read the record
        RecordAuditTrailController.SessionSummary summary = RecordAuditTrailController.getSessionsForRecord(CASE_ID)[0];
        System.assertEquals('Closed', summary.lifecycle);
        System.assert(summary.closed);
        System.assertEquals('Verified', summary.integrity);
        System.assertNotEquals(null, summary.lastVerifiedAt);
    }
}
