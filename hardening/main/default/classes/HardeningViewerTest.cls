/**
 * The viewer scenario of the hardening suite: a user with AgentLedger User and
 * read access to one of two private items, without access to the Secret field.
 * Runs as that user with System.runAs (a Standard User cannot run anonymous
 * Apex), which applies their record access and field-level security.
 *
 * Finds the viewer by last name ("Hardening viewer", created by
 * hardening/setup.mjs). Test-only metadata; not part of the package.
 */
@isTest
private class HardeningViewerTest {

    private static Id change(Id itemId, String values) {
        UpdateRecordAgentLedgerAction.Request r = new UpdateRecordAgentLedgerAction.Request();
        r.agentId = 'HardenTE'; r.recordId = itemId; r.fieldValues = values; r.reasoning = 'hardening change';
        Id runId = UpdateRecordAgentLedgerAction.execute(new List<UpdateRecordAgentLedgerAction.Request>{ r })[0].sessionId;
        AgentAuditRecorder.sealSession(runId);
        return runId;
    }

    @isTest
    static void theViewerSeesOnlyWhatTheyMay() {
        User viewer = [SELECT Id FROM User WHERE LastName = 'Hardening viewer' AND IsActive = true LIMIT 1];
        Hardening_Item__c shared = new Hardening_Item__c(Name = 'Shared item', Status__c = 'New', Secret__c = 'old-secret');
        Hardening_Item__c hidden = new Hardening_Item__c(Name = 'Hidden item', Status__c = 'New', Secret__c = 'other');
        insert new List<Hardening_Item__c>{ shared, hidden };
        insert new Hardening_Item__Share(ParentId = shared.Id, UserOrGroupId = viewer.Id, AccessLevel = 'Read');
        Id runShared = change(shared.Id, '{"Status__c": "Reviewed", "Secret__c": "TOP-SECRET-VALUE"}');
        Id runHidden = change(hidden.Id, '{"Status__c": "Private"}');

        System.runAs(viewer) {
            System.assert(!Schema.SObjectType.Hardening_Item__c.fields.Secret__c.isAccessible(), 'setup: the viewer cannot read Secret');

            AgentLedgerTimelineController.Timeline t = AgentLedgerTimelineController.getTimeline(shared.Id, 10, null);
            System.assertEquals(1, t.runs.size(), 'the viewer sees the run on the shared item');
            String shown = JSON.serialize(t);
            System.assert(!shown.contains('TOP-SECRET-VALUE') && !shown.contains('old-secret'), 'no Secret value anywhere in the timeline');
            System.assert(shown.contains('Reviewed'), 'the readable change is shown');
            System.assertEquals(1, t.runs[0].entries[0].hiddenFieldChanges);

            AgentLedgerTimelineController.Timeline none = AgentLedgerTimelineController.getTimeline(hidden.Id, 10, null);
            System.assert(none.runs.isEmpty() && !none.hasMore, 'an empty timeline for a record the viewer cannot read');
            System.assert(!JSON.serialize(none).contains('Private'), 'nothing about the hidden run');
            Boolean blocked;

            AgentLedgerEvidence.ExportedRun ex = AgentLedgerEvidence.exportRun(runShared);
            System.assert(!ex.json.contains('TOP-SECRET-VALUE'), 'the export leaves out the Secret value');
            System.assertEquals(1, ex.hiddenEntries);

            blocked = false;
            try { AgentLedgerEvidence.exportRun(runHidden); } catch (Exception e) { blocked = true; }
            System.assert(blocked, 'no export of a run on a record the viewer cannot read');

            blocked = false;
            try { AgentLedgerTimelineController.verifyRun(runHidden); } catch (Exception e) { blocked = true; }
            System.assert(blocked, 'no verify of a run on a record the viewer cannot read');
            System.assertEquals('Verified', AgentLedgerTimelineController.verifyRun(runShared).integrity);

            for (AgentLedgerActivityController.RunRow r : AgentLedgerActivityController.getRuns(null, null, null, 200)) {
                System.assertNotEquals(runHidden, r.runId, 'the Agent Activity page does not list the hidden run');
            }
            System.assertEquals(0, [SELECT COUNT() FROM Agent_Audit_Record__c WHERE Audit_Session__c = :runHidden],
                'a direct query returns no entries of the hidden run');

            List<SObject> entries = [SELECT Id, Reasoning__c FROM Agent_Audit_Record__c WHERE Audit_Session__c = :runShared];
            if (!entries.isEmpty()) {
                blocked = false;
                try { entries[0].put('Reasoning__c', 'edited'); update entries; } catch (Exception e) { blocked = true; }
                System.assert(blocked, 'the viewer cannot edit an entry');
                blocked = false;
                try { delete entries; } catch (Exception e) { blocked = true; }
                System.assert(blocked, 'the viewer cannot delete an entry');
            }
        }
        System.assert(AgentAuditRecorder.verifySession(runShared).valid, 'nothing the viewer tried changed the run');
    }
}
