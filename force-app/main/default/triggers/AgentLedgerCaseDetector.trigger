// Logs Case changes an agent makes without an AgentLedger action (AgentLedgerChangeDetector).
trigger AgentLedgerCaseDetector on Case (after insert, after update, after delete) {
    AgentLedgerChangeDetector.handle();
}
