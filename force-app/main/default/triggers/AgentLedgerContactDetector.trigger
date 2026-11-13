// Logs Contact changes an agent makes without an AgentLedger action (AgentLedgerChangeDetector).
trigger AgentLedgerContactDetector on Contact (after insert, after update, after delete) {
    AgentLedgerChangeDetector.handle();
}
