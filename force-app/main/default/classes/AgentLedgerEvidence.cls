/**
 * AgentLedgerEvidence
 *
 * Exports a run as a JSON document that the open-source verifiers check
 * outside Salesforce:
 *
 *   npx @vluthra/agent-ledger verify run.json
 *   python -m agentledger verify run.json
 *
 * The document has the { session, records } shape of the npm and PyPI
 * libraries' exported sessions. Each record is exactly the content its v2 hash
 * covers (HashChainService.entryContentV2) plus the stored hash, so the
 * verifiers recompute every hash, the chain and the Merkle root from the file
 * alone. A "salesforce" block adds where the run came from; the verifiers
 * ignore it.
 *
 * Who may export: whoever may see the run (AgentLedgerAccess.canViewRun).
 * Values of fields the exporting user cannot read are not exported: the
 * entries that recorded them are listed under salesforce.hiddenFields, and
 * they will not verify, because their content is incomplete.
 */
public without sharing class AgentLedgerEvidence {

    public static final String FORMAT = 'agentledger-salesforce-export/v1';
    private static final String HIDDEN = '[hidden]';

    public class EvidenceException extends Exception {}

    public class ExportedRun {
        @AuraEnabled public String fileName;
        @AuraEnabled public String json;
        @AuraEnabled public Integer hiddenEntries;
    }

    /** The run as an exported session document, for the timeline's Export button. */
    @AuraEnabled
    public static ExportedRun exportRun(Id runId) {
        try {
            return build(runId);
        } catch (EvidenceException e) {
            throw new AuraHandledException(e.getMessage());
        }
    }

    @TestVisible
    private static ExportedRun build(Id runId) {
        if (runId == null || !AgentLedgerAccess.canViewRun(runId)) {
            throw new EvidenceException('You do not have access to this agent run.');
        }
        Agent_Audit_Session__c run = [
            SELECT Id, Name, Session_Id__c, Agent_Id__c, Start_Time__c, End_Time__c, Status__c, Mode__c,
                   Record_Count__c, Merkle_Root__c, Hash_Version__c, Platform__c, Related_Record_Id__c,
                   Related_Object__c, Agent_Version__c, Instructions_Hash__c, Policy_Reference__c, Policy_Hash__c
            FROM Agent_Audit_Session__c WHERE Id = :runId
        ];
        if (run.Hash_Version__c != 'v2') {
            throw new EvidenceException(
                'This run was recorded before AgentLedger v2 hashing. Verify it in Salesforce; export needs a v2 run.');
        }
        List<Agent_Audit_Record__c> entries = [
            SELECT Id, Sequence_Number__c, Entry_Id__c, Timestamp_Text__c, Agent_Id__c, Action_Type__c,
                   Input_Context__c, Output_Result__c, Reasoning__c, Summary__c, Target_Record_Id__c,
                   Target_Object__c, Field_Changes__c, Capture_Method__c, Turn_Number__c, Agent_Version__c,
                   Instructions_Hash__c, Policy_Reference__c, Policy_Hash__c, Record_Hash__c, Previous_Hash__c
            FROM Agent_Audit_Record__c
            WHERE Audit_Session__c = :runId
            ORDER BY Sequence_Number__c ASC
        ];

        // A run can touch several records: the content of steps on records the
        // exporting user cannot read is not exported.
        Set<String> entryRecords = new Set<String>();
        for (Agent_Audit_Record__c e : entries) {
            String rec = AgentLedgerAccess.entryRecord(e.Target_Record_Id__c, run.Related_Record_Id__c);
            if (rec != null) {
                entryRecords.add(rec);
            }
        }
        Set<String> readable = AgentLedgerAccess.readableRecords(entryRecords);

        List<Object> records = new List<Object>();
        List<Object> hidden = new List<Object>();
        for (Agent_Audit_Record__c e : entries) {
            String rec = AgentLedgerAccess.entryRecord(e.Target_Record_Id__c, run.Related_Record_Id__c);
            List<String> hiddenFields = rec != null && !readable.contains(rec)
                ? hideRestrictedEntry(e)
                : hideUnreadableFields(e);
            Map<String, Object> record = HashChainService.entryContentV2(e, run.Session_Id__c);
            record.put('hash', e.Record_Hash__c);
            records.add(record);
            if (!hiddenFields.isEmpty()) {
                hidden.add(new Map<String, Object>{
                    'sequenceNumber' => e.Sequence_Number__c == null ? null : e.Sequence_Number__c.intValue(),
                    'fields' => hiddenFields
                });
            }
        }

        Boolean closed = AgentAuditRecorder.isClosed(run.Status__c);
        Map<String, Object> metadata = new Map<String, Object>();
        putIfNotNull(metadata, 'agentVersion', run.Agent_Version__c);
        putIfNotNull(metadata, 'instructionsHash', run.Instructions_Hash__c);
        putIfNotNull(metadata, 'policyReference', run.Policy_Reference__c);
        putIfNotNull(metadata, 'policyHash', run.Policy_Hash__c);
        putIfNotNull(metadata, 'mode', run.Mode__c);

        Map<String, Object> session = new Map<String, Object>{
            'sessionId' => run.Session_Id__c,
            'agentId' => run.Agent_Id__c,
            'startTime' => iso(run.Start_Time__c),
            'endTime' => iso(run.End_Time__c),
            'recordCount' => run.Record_Count__c == null ? 0 : run.Record_Count__c.intValue(),
            'merkleRoot' => closed ? run.Merkle_Root__c : null,
            'status' => closed ? 'sealed' : 'active',
            'platform' => String.isBlank(run.Platform__c) ? 'salesforce' : run.Platform__c,
            'canonicalization' => 'v2',
            'merkle' => 'v2',
            'metadata' => metadata
        };

        Map<String, Object> source = new Map<String, Object>{
            'format' => FORMAT,
            'orgId' => UserInfo.getOrganizationId(),
            'runId' => run.Id,
            'runName' => run.Name,
            'relatedRecordId' => run.Related_Record_Id__c,
            'relatedObject' => run.Related_Object__c,
            'lifecycleStatus' => run.Status__c,
            'exportedAt' => iso(DateTime.now()),
            'exportedBy' => UserInfo.getUserId(),
            'hiddenFields' => hidden
        };

        ExportedRun result = new ExportedRun();
        result.json = JSON.serializePretty(new Map<String, Object>{
            'canonicalization' => 'v2',
            'merkle' => 'v2',
            'session' => session,
            'records' => records,
            'salesforce' => source
        });
        result.fileName = 'agentledger-' + run.Name + '.json';
        result.hiddenEntries = hidden.size();
        return result;
    }

    /** Replaces all content of an entry on a record the user cannot read. Works on the queried copy only. */
    @TestVisible
    private static List<String> hideRestrictedEntry(Agent_Audit_Record__c e) {
        e.Summary__c = HIDDEN;
        e.Reasoning__c = HIDDEN;
        e.Input_Context__c = HIDDEN;
        e.Output_Result__c = HIDDEN;
        e.Field_Changes__c = String.isBlank(e.Field_Changes__c) ? null : HIDDEN;
        e.Target_Record_Id__c = HIDDEN;
        return new List<String>{ '(record not accessible)' };
    }

    /**
     * Replaces values of fields the user cannot read, in an entry's field
     * changes and in a lookup's result, and returns those fields. Works on the
     * queried copy only; nothing is saved.
     */
    @TestVisible
    private static List<String> hideUnreadableFields(Agent_Audit_Record__c e) {
        List<String> hiddenFields = new List<String>();
        Map<String, Schema.SObjectField> fields = fieldMap(e.Target_Object__c);
        if (fields == null) {
            return hiddenFields;
        }
        if (String.isNotBlank(e.Field_Changes__c)) {
            try {
                List<Object> changes = (List<Object>) JSON.deserializeUntyped(e.Field_Changes__c);
                Boolean changed = false;
                for (Object o : changes) {
                    Map<String, Object> c = (Map<String, Object>) o;
                    String name = (String) c.get('field');
                    if (!AgentLedgerAccess.canReadField(fields, name)) {
                        c.put('before', HIDDEN);
                        c.put('after', HIDDEN);
                        hiddenFields.add(name);
                        changed = true;
                    }
                }
                if (changed) {
                    // The summary, request and result of a change repeat its values.
                    e.Field_Changes__c = JSON.serialize(changes);
                    e.Summary__c = HIDDEN;
                    e.Input_Context__c = HIDDEN;
                    e.Output_Result__c = HIDDEN;
                }
            } catch (Exception ex) {
                // Not a list of changes: exported as stored.
            }
        }
        if (String.isNotBlank(e.Output_Result__c) && e.Output_Result__c.trim().startsWith('{')) {
            try {
                Map<String, Object> values = (Map<String, Object>) JSON.deserializeUntyped(e.Output_Result__c);
                Boolean changed = false;
                for (String name : values.keySet()) {
                    if (!AgentLedgerAccess.canReadField(fields, name)) {
                        values.put(name, HIDDEN);
                        if (!hiddenFields.contains(name)) {
                            hiddenFields.add(name);
                        }
                        changed = true;
                    }
                }
                if (changed) {
                    e.Output_Result__c = JSON.serialize(values);
                }
            } catch (Exception ex) {
                // Not a JSON object of values: exported as stored.
            }
        }
        return hiddenFields;
    }

    private static Map<String, Schema.SObjectField> fieldMap(String objectName) {
        if (String.isBlank(objectName)) {
            return null;
        }
        Schema.SObjectType t = Schema.getGlobalDescribe().get(objectName.toLowerCase());
        return t == null ? null : t.getDescribe().fields.getMap();
    }

    private static String iso(DateTime d) {
        return d == null ? null : d.formatGmt('yyyy-MM-dd\'T\'HH:mm:ss.SSS\'Z\'');
    }

    private static void putIfNotNull(Map<String, Object> m, String key, Object value) {
        if (value != null) {
            m.put(key, value);
        }
    }
}
