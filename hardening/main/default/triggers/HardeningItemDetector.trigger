trigger HardeningItemDetector on Hardening_Item__c (after insert, after update, after delete) {
    AgentLedgerChangeDetector.handle();
}
