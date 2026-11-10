// Runs are created only by AgentLedger; protected fields cannot change; runs cannot be deleted. See AgentLedgerGuard.
trigger AgentLedgerRunTrigger on Agent_Audit_Session__c (before insert, before update, before delete) {
    if (Trigger.isInsert) {
        AgentLedgerGuard.beforeInsert(Trigger.new);
    } else if (Trigger.isUpdate) {
        AgentLedgerGuard.beforeRunUpdate(Trigger.new, Trigger.oldMap);
    } else {
        AgentLedgerGuard.beforeRunDelete(Trigger.old);
    }
}
