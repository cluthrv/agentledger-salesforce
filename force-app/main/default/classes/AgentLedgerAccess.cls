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
