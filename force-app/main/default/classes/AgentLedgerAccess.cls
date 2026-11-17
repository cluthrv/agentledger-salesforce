/**
 * AgentLedgerAccess
 *
 * Who may see a run. Runs are private (owned by the user they started for),
 * but the people who work on a record need to see what agents did to it. A
 * user may therefore see a run when Salesforce gives them read access to the
 * run itself (owner, sharing, View All) or to the run's related record.
 *
 * Uses UserRecordAccess, so record access follows the org's own sharing
 * configuration. Field-level security is applied separately where field
 * values are shown.
 */
public without sharing class AgentLedgerAccess {

    /** Answers to use instead of UserRecordAccess, for tests: record Id to readable. */
    @TestVisible
    private static Map<Id, Boolean> readAccessForTest;

    /** Whether the running user can read the record. */
    public static Boolean canReadRecord(Id recordId) {
        if (recordId == null) {
            return false;
        }
        if (readAccessForTest != null && readAccessForTest.containsKey(recordId)) {
            return readAccessForTest.get(recordId);
        }
        List<UserRecordAccess> access = [
            SELECT RecordId, HasReadAccess FROM UserRecordAccess
            WHERE UserId = :UserInfo.getUserId() AND RecordId = :recordId
        ];
        return !access.isEmpty() && access[0].HasReadAccess;
    }

    /**
     * Of the given record Ids (15 or 18 characters), those the running user
     * can read. Ids that are not record Ids are left out.
     */
    public static Set<String> readableRecords(Set<String> recordIds) {
        Set<String> readable = new Set<String>();
        Map<Id, Set<String>> formsById = new Map<Id, Set<String>>();
        for (String s : recordIds) {
            if (String.isBlank(s)) {
                continue;
            }
            Id recordId;
            try {
                recordId = Id.valueOf(s);
            } catch (Exception e) {
                continue;
            }
            if (readAccessForTest != null && readAccessForTest.containsKey(recordId)) {
                if (readAccessForTest.get(recordId)) {
                    readable.add(s);
                }
                continue;
            }
            if (!formsById.containsKey(recordId)) {
                formsById.put(recordId, new Set<String>());
            }
            formsById.get(recordId).add(s);
        }
        List<Id> pending = new List<Id>(formsById.keySet());
        Integer i = 0;
        while (i < pending.size()) {
            List<Id> chunk = new List<Id>();
            while (i < pending.size() && chunk.size() < 200) {
                chunk.add(pending[i++]);
            }
            for (UserRecordAccess a : [
                SELECT RecordId, HasReadAccess FROM UserRecordAccess
                WHERE UserId = :UserInfo.getUserId() AND RecordId IN :chunk
            ]) {
                if (a.HasReadAccess) {
                    readable.addAll(formsById.get(a.RecordId));
                }
            }
        }
        return readable;
    }

    /** The record an entry is about: its target, or else its run's related record. */
    public static String entryRecord(String targetRecordId, String runRelatedRecordId) {
        return String.isNotBlank(targetRecordId) ? targetRecordId : runRelatedRecordId;
    }

    /** Answers to use instead of field-level security, for tests: field name (lower case) to readable. */
    @TestVisible
    private static Map<String, Boolean> fieldReadableForTest;

    /**
     * Whether the running user may read a field, given its object's field map.
     * Unknown fields and a missing map count as readable: there is nothing to
     * check them against.
     */
    public static Boolean canReadField(Map<String, Schema.SObjectField> fields, String fieldName) {
        if (fieldName == null) {
            return true;
        }
        if (fieldReadableForTest != null && fieldReadableForTest.containsKey(fieldName.toLowerCase())) {
            return fieldReadableForTest.get(fieldName.toLowerCase());
        }
        Schema.SObjectField f = fields == null ? null : fields.get(fieldName.toLowerCase());
        return f == null || f.getDescribe().isAccessible();
    }

    /** Whether the running user may see a run: the run itself, or its related record. */
    public static Boolean canViewRun(Id runId) {
        if (canReadRecord(runId)) {
            return true;
        }
        List<Agent_Audit_Session__c> runs = [SELECT Related_Record_Id__c FROM Agent_Audit_Session__c WHERE Id = :runId];
        if (runs.isEmpty() || String.isBlank(runs[0].Related_Record_Id__c)) {
            return false;
        }
        try {
            return canReadRecord(Id.valueOf(runs[0].Related_Record_Id__c));
        } catch (StringException e) {
            return false;
        }
    }
}
