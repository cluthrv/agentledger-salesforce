/**
 * AgentLedgerRuns
 *
 * Automatic runs: an AgentLedger action that is not given a Session Id uses
 * the agent's open run for the current user (and the same related record,
 * when one is given), or starts a new one. Agents therefore do not have to
 * call Start, and a run that is never closed is closed later by
 * AgentLedgerAutoClose and marked Incomplete.
 */
public with sharing class AgentLedgerRuns {

    /**
     * The open run to record into, or null when AgentLedger is turned off for
     * this agent.
     *
     * @param agentId         the agent's Agent Id
     * @param relatedRecordId the record the step is about; may be blank
     */
    public static Id findOrStart(String agentId, String relatedRecordId) {
        AgentLedgerSettings.Resolved settings = AgentLedgerSettings.forAgent(agentId);
        if (!settings.enabled) {
            return null;
        }
        String related = AgentAuditRecorder.normalizeId(relatedRecordId);
        DateTime activeSince = DateTime.now().addMinutes(-settings.autoCloseMinutes);
        Id me = UserInfo.getUserId();

        List<Agent_Audit_Session__c> open = related == null
            ? [SELECT Id FROM Agent_Audit_Session__c
               WHERE Status__c = :AgentAuditRecorder.STATUS_ACTIVE AND Agent_Id__c = :agentId
                 AND Started_By__c = :me AND Last_Activity__c >= :activeSince
               ORDER BY Last_Activity__c DESC LIMIT 1]
            : [SELECT Id FROM Agent_Audit_Session__c
               WHERE Status__c = :AgentAuditRecorder.STATUS_ACTIVE AND Agent_Id__c = :agentId
                 AND Started_By__c = :me AND Related_Record_Id__c = :related AND Last_Activity__c >= :activeSince
               ORDER BY Last_Activity__c DESC LIMIT 1];
        if (!open.isEmpty()) {
            return open[0].Id;
        }
        return AgentAuditRecorder.startSession(agentId, related, 'agentforce');
    }

    /** The given Session Id, or the agent's open run when none is given. */
    public static Id resolve(Id sessionId, String agentId, String relatedRecordId) {
        return sessionId != null ? sessionId : findOrStart(agentId, relatedRecordId);
    }
}
