/**
 * AgentLedgerScheduler
 *
 * The class the hourly auto-close job schedules. It starts AgentLedgerAutoClose
 * by name, so it has no compile-time dependency on the rest of AgentLedger:
 * Salesforce blocks deploying (and upgrading a package with) any class a
 * scheduled job depends on, and this keeps that set to this one class, which
 * never needs to change.
 */
public without sharing class AgentLedgerScheduler implements Schedulable {

    public void execute(SchedulableContext context) {
        Type job = Type.forName('AgentLedgerAutoClose');
        if (job != null) {
            Database.executeBatch((Database.Batchable<SObject>) job.newInstance(), 20);
        }
    }
}
