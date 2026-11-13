/**
 * AgentLedgerGuard
 *
 * Keeps the ledger append-only. Entries cannot be edited or deleted, and a
 * run's protected fields (identity, status, counts, root, integrity) cannot be
 * changed, except by AgentLedger's own code. Called from the triggers on
 * Agent_Audit_Record__c and Agent_Audit_Session__c.
 *
 * For tamper-detection testing, a user with the custom permission
 * AgentLedger_Allow_Entry_Edits (permission set AgentLedger Tamper Testing)
 * may edit anyway; verification still detects every such edit.
 *
 * This raises the bar for ordinary users and admins working through the UI or
 * API. It does not stop someone who can deploy code or deactivate triggers;
 * export and anchoring address that.
 */
public with sharing class AgentLedgerGuard {

    public static final String EDIT_PERMISSION = 'AgentLedger_Allow_Entry_Edits';

    /** Run fields only AgentLedger code may change. */
    public static final List<Schema.SObjectField> PROTECTED_RUN_FIELDS = new List<Schema.SObjectField>{
        Agent_Audit_Session__c.Session_Id__c,
        Agent_Audit_Session__c.Agent_Id__c,
        Agent_Audit_Session__c.Status__c,
        Agent_Audit_Session__c.Record_Count__c,
        Agent_Audit_Session__c.Merkle_Root__c,
        Agent_Audit_Session__c.Hash_Version__c,
        Agent_Audit_Session__c.Mode__c,
        Agent_Audit_Session__c.Integrity__c,
        Agent_Audit_Session__c.Last_Verified_At__c,
        Agent_Audit_Session__c.Related_Record_Id__c,
        Agent_Audit_Session__c.Start_Time__c,
        Agent_Audit_Session__c.End_Time__c,
        Agent_Audit_Session__c.Started_By__c,
        Agent_Audit_Session__c.Last_Activity__c,
        Agent_Audit_Session__c.Agent_Version__c,
        Agent_Audit_Session__c.Instructions_Hash__c,
        Agent_Audit_Session__c.Policy_Reference__c,
        Agent_Audit_Session__c.Policy_Hash__c
    };

    private static Integer ledgerWriteDepth = 0;
    private static Integer recordedChangeDepth = 0;

    @TestVisible
    private static Boolean allowManualEditsForTest = false;

    /** Mark the start of a write by AgentLedger code. Pair with endLedgerWrite in a finally block. */
    public static void beginLedgerWrite() {
        ledgerWriteDepth++;
    }

    public static void endLedgerWrite() {
        ledgerWriteDepth = Math.max(0, ledgerWriteDepth - 1);
    }

    public static Boolean isLedgerWrite() {
        return ledgerWriteDepth > 0;
    }

    /**
     * Mark a business record change made by a recorded action, which logs it
     * itself; the change detector skips it. Pair with endRecordedChange in a
     * finally block.
     */
    public static void beginRecordedChange() {
        recordedChangeDepth++;
    }

    public static void endRecordedChange() {
        recordedChangeDepth = Math.max(0, recordedChangeDepth - 1);
    }

    public static Boolean isRecordedChange() {
        return recordedChangeDepth > 0;
    }

    /** True when the running user may edit entries for testing. */
    public static Boolean manualEditsAllowed() {
        return allowManualEditsForTest || FeatureManagement.checkPermission(EDIT_PERMISSION);
    }

    private static Boolean bypass() {
        return isLedgerWrite() || manualEditsAllowed();
    }

    // ── Creation: only AgentLedger code creates runs, entries and snapshots ──

    public static void beforeInsert(List<SObject> rows) {
        if (bypass()) {
            return;
        }
        for (SObject row : rows) {
            row.addError('AgentLedger records are created only by AgentLedger.');
        }
    }

    // ── Snapshots: never changed or deleted ──

    public static void beforeSnapshotChange(List<SObject> rows) {
        if (bypass()) {
            return;
        }
        for (SObject row : rows) {
            row.addError('Agent instruction snapshots are a permanent record and cannot be changed or deleted.');
        }
    }

    // ── Entries ──

    public static void beforeEntryUpdate(List<Agent_Audit_Record__c> entries) {
        if (bypass()) {
            return;
        }
        for (Agent_Audit_Record__c e : entries) {
            e.addError('AgentLedger entries are a permanent record and cannot be edited.');
        }
    }

    public static void beforeEntryDelete(List<Agent_Audit_Record__c> entries) {
        if (bypass()) {
            return;
        }
        for (Agent_Audit_Record__c e : entries) {
            e.addError('AgentLedger entries are a permanent record and cannot be deleted.');
        }
    }

    // ── Runs ──

    public static void beforeRunUpdate(List<Agent_Audit_Session__c> runs, Map<Id, Agent_Audit_Session__c> oldRuns) {
        if (bypass()) {
            return;
        }
        for (Agent_Audit_Session__c run : runs) {
            Agent_Audit_Session__c old = oldRuns.get(run.Id);
            for (Schema.SObjectField f : PROTECTED_RUN_FIELDS) {
                if (run.get(f) != old.get(f)) {
                    run.addError(f.getDescribe().getLabel() + ' of an AgentLedger run cannot be changed.');
                    break;
                }
            }
        }
    }

    public static void beforeRunDelete(List<Agent_Audit_Session__c> runs) {
        if (bypass()) {
            return;
        }
        for (Agent_Audit_Session__c run : runs) {
            run.addError('AgentLedger runs are a permanent record and cannot be deleted.');
        }
    }
}
