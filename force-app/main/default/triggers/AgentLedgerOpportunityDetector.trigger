// Logs Opportunity changes an agent makes without an AgentLedger action (AgentLedgerChangeDetector).
trigger AgentLedgerOpportunityDetector on Opportunity (after insert, after update, after delete) {
    AgentLedgerChangeDetector.handle();
}
