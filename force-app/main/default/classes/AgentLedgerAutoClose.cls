/**
 * AgentLedgerAutoClose
 *
 * Closes runs that were started but never closed: open runs with no activity
 * for longer than the org's auto-close time (AgentLedger Setting, default 30
 * minutes). A run with entries is sealed, so its entries are fingerprinted
 * like any closed run; either way it is marked Incomplete, so a missing close
 * is visible rather than silent.
 *
 * Schedule it once (hourly):   AgentLedgerAutoClose.scheduleHourly();
 * Or run it now:               Database.executeBatch(new AgentLedgerAutoClose(), 20);
 *
 * Runs without sharing, so it closes every user's runs.
 */
public without sharing class AgentLedgerAutoClose implements Database.Batchable<SObject>, Schedulable {

    public static final String JOB_NAME = 'AgentLedger auto-close';
    public static final Integer BATCH_SIZE = 20;

    public Database.QueryLocator start(Database.BatchableContext context) {
        DateTime cutoff = cutoff();
        return Database.getQueryLocator([
            SELECT Id, Record_Count__c
            FROM Agent_Audit_Session__c
            WHERE Status__c = :AgentAuditRecorder.STATUS_ACTIVE
              AND (Last_Activity__c < :cutoff OR (Last_Activity__c = null AND Start_Time__c < :cutoff))
        ]);
    }

    public void execute(Database.BatchableContext context, List<Agent_Audit_Session__c> runs) {
        closeAll(runs);
    }

    public void finish(Database.BatchableContext context) {
    }

    public void execute(SchedulableContext context) {
        Database.executeBatch(new AgentLedgerAutoClose(), BATCH_SIZE);
    }

    /** Close the given open runs as Incomplete. Returns how many were closed. */
    public static Integer closeAll(List<Agent_Audit_Session__c> runs) {
        Integer closed = 0;
        for (Agent_Audit_Session__c run : runs) {
            try {
                if (run.Record_Count__c != null && run.Record_Count__c > 0) {
                    MerkleTreeService.sealSession(run.Id, AgentAuditRecorder.STATUS_INCOMPLETE);
                } else {
                    AgentLedgerGuard.beginLedgerWrite();
                    try {
                        update new Agent_Audit_Session__c(Id = run.Id, Status__c = AgentAuditRecorder.STATUS_INCOMPLETE,
                                                          End_Time__c = DateTime.now());
                    } finally {
                        AgentLedgerGuard.endLedgerWrite();
                    }
                }
                closed++;
            } catch (Exception e) {
                // A run that changed state meanwhile (closed by its agent) is skipped.
                System.debug(LoggingLevel.WARN, 'AgentLedger auto-close skipped ' + run.Id + ': ' + e.getMessage());
            }
        }
        return closed;
    }

    /** Schedule the job to run at the top of every hour. Returns the job Id. */
    public static Id scheduleHourly() {
        return System.schedule(JOB_NAME, '0 0 * * * ?', new AgentLedgerAutoClose());
    }

    private static DateTime cutoff() {
        return DateTime.now().addMinutes(-AgentLedgerSettings.orgDefault().autoCloseMinutes);
    }
}
