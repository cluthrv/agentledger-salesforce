/**
 * AgentLedgerEvidenceTest
 *
 * Exporting a run for verification outside Salesforce. The export must parse
 * back to records whose hashes, chain and Merkle root recompute exactly as the
 * open-source verifiers do; scripts/check-export.mjs runs the real npm verifier
 * against an export from an org.
 */
@isTest
private class AgentLedgerEvidenceTest {

    private static final String AGENT = 'CaseEscalationAgent';

    private static void settings() {
        AgentLedgerSettings.recordsForTest = (List<AgentLedger_Setting__mdt>) System.JSON.deserialize(
            '[{"DeveloperName":"Org_Default","Enabled__c":true,"Mode__c":"Tamper_Evident","Store_Field_Values__c":true}]',
            List<AgentLedger_Setting__mdt>.class);
        AgentLedgerPolicy.definitionsForTest = new Map<String, AgentLedgerPolicy.AgentDefinition>();
    }

    /** A closed run on a Case: a lookup, a decision with awkward text, and an update. */
    private static Id closedRun(Case c) {
        GetRecordAgentLedgerAction.Request get = new GetRecordAgentLedgerAction.Request();
        get.recordId = c.Id;
        get.fields = 'Subject, Status, Priority';
        get.agentId = AGENT;
        Id runId = GetRecordAgentLedgerAction.execute(new List<GetRecordAgentLedgerAction.Request>{ get })[0].sessionId;

        AgentAuditRecorder.recordAction(runId, AGENT, 'Decision', 'Priority "High" \\ Status New',
            'Escalate — café 中文 😀', 'Meets the criteria.\nSecond line.');

        UpdateRecordAgentLedgerAction.Request upd = new UpdateRecordAgentLedgerAction.Request();
        upd.recordId = c.Id;
        upd.fieldValues = '{"Status": "Escalated"}';
        upd.reasoning = 'High priority and not yet escalated.';
        upd.agentId = AGENT;
        upd.sessionId = runId;
        UpdateRecordAgentLedgerAction.execute(new List<UpdateRecordAgentLedgerAction.Request>{ upd });

        AgentAuditRecorder.sealSession(runId);
        return runId;
    }

    private static Case newCase() {
        Case c = new Case(Subject = 'Export test', Status = 'New', Priority = 'High', Origin = 'Web');
        insert c;
        return c;
    }

    /** Recomputes a record's v2 hash from the exported content, as the verifiers do. */
    private static String rehash(Map<String, Object> record) {
        Map<String, Object> content = record.clone();
        content.remove('hash');
        return HashChainService.sha256(HashChainService.RECORD_HASH_V2_TAG + AgentLedgerCanonical.serialize(content));
    }

    @isTest
    static void anExportRecomputesExactly() {
        settings();
        Case c = newCase();
        Id runId = closedRun(c);

        AgentLedgerEvidence.ExportedRun ex = AgentLedgerEvidence.exportRun(runId);
        System.assert(ex.fileName.startsWith('agentledger-') && ex.fileName.endsWith('.json'), ex.fileName);
        System.assertEquals(0, ex.hiddenEntries);

        Map<String, Object> doc = (Map<String, Object>) JSON.deserializeUntyped(ex.json);
        System.assertEquals('v2', doc.get('canonicalization'));
        System.assertEquals('v2', doc.get('merkle'));
        Map<String, Object> session = (Map<String, Object>) doc.get('session');
        List<Object> records = (List<Object>) doc.get('records');
        System.assertEquals(3, records.size());
        System.assertEquals(3, session.get('recordCount'));
        System.assertEquals('sealed', session.get('status'));

        Agent_Audit_Session__c run = [SELECT Session_Id__c, Merkle_Root__c FROM Agent_Audit_Session__c WHERE Id = :runId];
        System.assertEquals(run.Session_Id__c, session.get('sessionId'));

        List<String> hashes = new List<String>();
        String previous = null;
        for (Object o : records) {
            Map<String, Object> r = (Map<String, Object>) o;
            System.assertEquals(r.get('hash'), rehash(r), 'record ' + r.get('sequenceNumber') + ' recomputes');
            System.assertEquals(previous, r.get('previousHash'), 'chain linkage');
            System.assertEquals(run.Session_Id__c, r.get('sessionId'));
            previous = (String) r.get('hash');
            hashes.add(previous);
        }
        System.assertEquals(run.Merkle_Root__c, session.get('merkleRoot'));
        System.assertEquals(run.Merkle_Root__c, MerkleTreeService.computeRoot(hashes, 'v2'));

        Map<String, Object> source = (Map<String, Object>) doc.get('salesforce');
        System.assertEquals(AgentLedgerEvidence.FORMAT, source.get('format'));
        System.assertEquals(String.valueOf(runId), source.get('runId'));
    }

    @isTest
    static void anOpenRunExportsWithoutARoot() {
        settings();
        Case c = newCase();
        GetRecordAgentLedgerAction.Request get = new GetRecordAgentLedgerAction.Request();
        get.recordId = c.Id;
        get.agentId = AGENT;
        Id runId = GetRecordAgentLedgerAction.execute(new List<GetRecordAgentLedgerAction.Request>{ get })[0].sessionId;
        Map<String, Object> session = (Map<String, Object>)
            ((Map<String, Object>) JSON.deserializeUntyped(AgentLedgerEvidence.exportRun(runId).json)).get('session');
        System.assertEquals('active', session.get('status'));
        System.assertEquals(null, session.get('merkleRoot'));
    }

    @isTest
    static void unreadableFieldValuesAreNotExported() {
        settings();
        Case c = newCase();
        Id runId = closedRun(c);

        AgentLedgerAccess.fieldReadableForTest = new Map<String, Boolean>{ 'status' => false };
        AgentLedgerEvidence.ExportedRun ex = AgentLedgerEvidence.exportRun(runId);
        System.assertEquals(2, ex.hiddenEntries, 'the lookup and the update recorded Status');
        System.assert(!ex.json.contains('Escalated'), 'no Status value anywhere, summaries included');
        System.assert(ex.json.contains('[hidden]'));

        Map<String, Object> doc = (Map<String, Object>) JSON.deserializeUntyped(ex.json);
        Integer failing = 0;
        for (Object o : (List<Object>) doc.get('records')) {
            Map<String, Object> r = (Map<String, Object>) o;
            if (r.get('hash') != rehash(r)) {
                failing++;
            }
        }
        System.assertEquals(2, failing, 'entries with hidden values do not verify');
        List<Object> hidden = (List<Object>) ((Map<String, Object>) doc.get('salesforce')).get('hiddenFields');
        System.assertEquals(2, hidden.size());
    }

    @isTest
    static void theTimelineHidesValuesOfUnreadableFields() {
        settings();
        Case c = newCase();
        closedRun(c);
        AgentLedgerAccess.fieldReadableForTest = new Map<String, Boolean>{ 'status' => false };
        AgentLedgerTimelineController.RunView run = AgentLedgerTimelineController.getTimeline(c.Id, 10, null).runs[0];
        for (AgentLedgerTimelineController.EntryView e : run.entries) {
            String shown = e.summary + ' ' + e.inputContext + ' ' + e.outputResult;
            System.assert(!shown.contains('Escalated') && !shown.contains('Status: New'), e.typeLabel + ': ' + shown);
            for (AgentLedgerTimelineController.FieldChangeView fc : e.fieldChanges) {
                System.assertNotEquals('Status', fc.field);
            }
        }
    }

    @isTest
    static void exportNeedsAccessToTheRun() {
        settings();
        Case c = newCase();
        Id runId = closedRun(c);
        AgentLedgerAccess.readAccessForTest = new Map<Id, Boolean>{ runId => false, c.Id => false };
        try {
            AgentLedgerEvidence.exportRun(runId);
            System.assert(false, 'expected an error');
        } catch (AuraHandledException e) {
            System.assert(true);
        }
    }

    @isTest
    static void runsBeforeV2AreNotExported() {
        settings();
        Case c = newCase();
        Id runId = closedRun(c);
        AgentLedgerGuard.beginLedgerWrite();
        update new Agent_Audit_Session__c(Id = runId, Hash_Version__c = 'v1');
        AgentLedgerGuard.endLedgerWrite();
        try {
            AgentLedgerEvidence.build(runId);
            System.assert(false, 'expected an error');
        } catch (AgentLedgerEvidence.EvidenceException e) {
            System.assert(e.getMessage().contains('before AgentLedger v2'), e.getMessage());
        }
    }
}
