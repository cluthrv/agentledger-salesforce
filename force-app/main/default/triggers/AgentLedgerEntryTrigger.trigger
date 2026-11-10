// Keeps AgentLedger entries append-only and created only by AgentLedger. See AgentLedgerGuard.
trigger AgentLedgerEntryTrigger on Agent_Audit_Record__c (before insert, before update, before delete) {
    if (Trigger.isInsert) {
        AgentLedgerGuard.beforeInsert(Trigger.new);
    } else if (Trigger.isUpdate) {
        AgentLedgerGuard.beforeEntryUpdate(Trigger.new);
    } else {
        AgentLedgerGuard.beforeEntryDelete(Trigger.old);
    }
}
