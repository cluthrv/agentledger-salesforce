/**
 * The change-detector scenario of the hardening suite, against the installed
 * package and the org's real settings (no test settings are injected).
 *
 * Only a real agent's action runs with the INVOCABLE_ACTION request type, which
 * neither anonymous Apex nor a test can produce, so these tests answer "yes"
 * through the detector's agentActionForTest hook. That a person's own change is
 * not flagged is checked for real by the 'detector' scenario in run.mjs.
 *
 * Hardening_Item__c has its detector trigger from hardening/make-metadata.mjs:
 * the documented way to watch another object.
 *
 * Test-only metadata; not part of the package.
 */
@isTest
private class HardeningDetectorTest {

    private static List<Agent_Audit_Record__c> detected(Id recordId) {
        return [
            SELECT Audit_Session__c, Action_Type__c, Field_Changes__c, Summary__c, Agent_Id__c
            FROM Agent_Audit_Record__c
            WHERE Capture_Method__c = 'Change_Detector' AND Target_Record_Id__c = :recordId
        ];
    }

    private static UpdateRecordAgentLedgerAction.Result recordedUpdate(Id recordId, String values) {
        UpdateRecordAgentLedgerAction.Request u = new UpdateRecordAgentLedgerAction.Request();
        u.agentId = 'HardenTE'; u.recordId = recordId; u.fieldValues = values; u.reasoning = 'recorded update';
        return UpdateRecordAgentLedgerAction.execute(new List<UpdateRecordAgentLedgerAction.Request>{ u })[0];
    }

    @isTest
    static void anAgentChangeOnAShippedObjectIsLogged() {
        Case c = new Case(Subject = 'Detector', Status = 'New', Origin = 'Web');
        insert c;
        AgentLedgerChangeDetector.agentActionForTest = true;
        update new Case(Id = c.Id, Status = 'Working');
        AgentLedgerChangeDetector.agentActionForTest = null;

        List<Agent_Audit_Record__c> es = detected(c.Id);
        System.assertEquals(1, es.size(), 'one detected entry');
        System.assertEquals('Data_Change', es[0].Action_Type__c);
        System.assertEquals(AgentLedgerChangeDetector.UNIDENTIFIED_AGENT, es[0].Agent_Id__c, 'no open run, so an unidentified agent');
        System.assert(es[0].Field_Changes__c.contains('Working'), es[0].Field_Changes__c);
    }

    @isTest
    static void aChangeOnAnObjectWithItsOwnTriggerJoinsTheOpenRun() {
        Hardening_Item__c item = new Hardening_Item__c(Name = 'Detector item', Amount__c = 5, Status__c = 'New');
        insert item;
        AgentLedgerChangeDetector.agentActionForTest = true;
        UpdateRecordAgentLedgerAction.Result r = recordedUpdate(item.Id, '{"Status__c": "Recorded"}');
        System.assert(r.success && r.logged, 'recorded update: ' + r);
        update new Hardening_Item__c(Id = item.Id, Amount__c = 7);
        AgentLedgerChangeDetector.agentActionForTest = null;

        List<Agent_Audit_Record__c> es = detected(item.Id);
        System.assertEquals(1, es.size(), 'the recorded update is not logged twice; the direct one is logged once');
        System.assertEquals(r.sessionId, es[0].Audit_Session__c, 'joins the agent\'s open run');
        System.assertEquals('HardenTE', es[0].Agent_Id__c);
        System.assertEquals(2, [SELECT COUNT() FROM Agent_Audit_Record__c WHERE Audit_Session__c = :r.sessionId]);
        AgentAuditRecorder.sealSession(r.sessionId);
        System.assert(AgentAuditRecorder.verifySession(r.sessionId).valid, 'the run with a detected entry verifies');
    }

    @isTest
    static void inATamperEvidentRunAChangeThatCannotBeLoggedIsRefused() {
        Hardening_Item__c item = new Hardening_Item__c(Name = 'Refused item', Amount__c = 5);
        insert item;
        AgentLedgerChangeDetector.agentActionForTest = true;
        recordedUpdate(item.Id, '{"Status__c": "Recorded"}');
        AgentLedgerChangeDetector.failLoggingForTest = true;
        Boolean refused = false;
        try {
            update new Hardening_Item__c(Id = item.Id, Amount__c = 9);
        } catch (DmlException e) {
            refused = e.getMessage().contains('AgentLedger could not log this change');
        }
        AgentLedgerChangeDetector.failLoggingForTest = false;
        AgentLedgerChangeDetector.agentActionForTest = null;
        System.assert(refused, 'refused with AgentLedger\'s message');
        System.assertEquals(5, [SELECT Amount__c FROM Hardening_Item__c WHERE Id = :item.Id].Amount__c);
    }

    @isTest
    static void createsAndBulkChangesAreLogged() {
        AgentLedgerChangeDetector.agentActionForTest = true;
        List<Hardening_Item__c> items = new List<Hardening_Item__c>();
        for (Integer i = 0; i < 25; i++) {
            items.add(new Hardening_Item__c(Name = 'Bulk ' + i));
        }
        insert items;
        Integer afterInsert = [SELECT COUNT() FROM Agent_Audit_Record__c WHERE Capture_Method__c = 'Change_Detector'];
        AgentLedgerChangeDetector.agentActionForTest = null;
        System.assertEquals(21, afterInsert, '20 one by one and the other 5 in one entry');
        System.assertEquals(1, [SELECT COUNT() FROM Agent_Audit_Record__c
            WHERE Capture_Method__c = 'Change_Detector' AND Summary__c LIKE 'Created 5 more%']);
    }

    @isTest
    static void deletesAreLogged() {
        Hardening_Item__c item = new Hardening_Item__c(Name = 'Deleted item');
        insert item;
        AgentLedgerChangeDetector.agentActionForTest = true;
        delete item;
        AgentLedgerChangeDetector.agentActionForTest = null;
        List<Agent_Audit_Record__c> es = detected(item.Id);
        Boolean deleteLogged = false;
        for (Agent_Audit_Record__c e : es) {
            deleteLogged |= e.Action_Type__c == 'Delete';
        }
        System.assert(deleteLogged, 'delete logged: ' + es);
    }
}
