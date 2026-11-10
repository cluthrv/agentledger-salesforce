// Keeps AgentLedger entries append-only. See AgentLedgerGuard.
trigger AgentLedgerEntryTrigger on Agent_Audit_Record__c (before update, before delete) {
    if (Trigger.isUpdate) {
        AgentLedgerGuard.beforeEntryUpdate(Trigger.new);
    } else {
        AgentLedgerGuard.beforeEntryDelete(Trigger.old);
    }
}
