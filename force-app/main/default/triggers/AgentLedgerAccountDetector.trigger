// Logs Account changes an agent makes without an AgentLedger action (AgentLedgerChangeDetector).
trigger AgentLedgerAccountDetector on Account (after insert, after update, after delete) {
    AgentLedgerChangeDetector.handle();
}
