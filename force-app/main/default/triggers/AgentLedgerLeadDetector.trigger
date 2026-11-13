// Logs Lead changes an agent makes without an AgentLedger action (AgentLedgerChangeDetector).
trigger AgentLedgerLeadDetector on Lead (after insert, after update, after delete) {
    AgentLedgerChangeDetector.handle();
}
