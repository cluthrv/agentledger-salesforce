// Agent instruction snapshots are created only by AgentLedger and never changed. See AgentLedgerGuard.
trigger AgentLedgerSnapshotTrigger on Agent_Instructions_Snapshot__c (before insert, before update, before delete) {
    if (Trigger.isInsert) {
        AgentLedgerGuard.beforeInsert(Trigger.new);
    } else {
        AgentLedgerGuard.beforeSnapshotChange(Trigger.isDelete ? Trigger.old : Trigger.new);
    }
}
