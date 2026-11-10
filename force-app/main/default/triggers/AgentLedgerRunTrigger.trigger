// Protects AgentLedger run fields and blocks deleting runs. See AgentLedgerGuard.
trigger AgentLedgerRunTrigger on Agent_Audit_Session__c (before update, before delete) {
    if (Trigger.isUpdate) {
        AgentLedgerGuard.beforeRunUpdate(Trigger.new, Trigger.oldMap);
    } else {
        AgentLedgerGuard.beforeRunDelete(Trigger.old);
    }
}
