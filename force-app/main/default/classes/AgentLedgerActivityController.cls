/**
 * AgentLedgerActivityController
 *
 * Data for the Agent Activity page: recent runs across the org, filtered by
 * status, integrity or agent. Runs with sharing: admins (AgentLedger Admin has
 * View All) see every run, other users their own.
 */
public with sharing class AgentLedgerActivityController {

    private static final Integer MAX_ROWS = 200;

    public class RunRow {
        @AuraEnabled public Id runId;
        @AuraEnabled public String name;
        @AuraEnabled public String agent;
        @AuraEnabled public String status;
        @AuraEnabled public String integrity;
        @AuraEnabled public String mode;
        @AuraEnabled public DateTime startTime;
        @AuraEnabled public DateTime lastActivity;
        @AuraEnabled public String startedBy;
        @AuraEnabled public Integer steps;
        @AuraEnabled public String relatedRecordId;
        @AuraEnabled public String relatedObject;
        @AuraEnabled public String agentVersion;
    }

    /**
     * @param status    Active, Closed or Incomplete; blank for all
     * @param integrity Verified, Tampered or Not_Checked; blank for all
     * @param agent     part of an Agent Id; blank for all
     * @param maxRows   at most 200
     */
    @AuraEnabled
    public static List<RunRow> getRuns(String status, String integrity, String agent, Integer maxRows) {
        Integer rowLimit = maxRows == null || maxRows <= 0 ? 50 : Math.min(maxRows, MAX_ROWS);
        List<String> filters = new List<String>();
        Map<String, Object> binds = new Map<String, Object>{ 'rowLimit' => rowLimit };
        if (status == AgentAuditRecorder.STATUS_CLOSED) {
            filters.add('Status__c IN (\'Closed\', \'Sealed\', \'Verified\', \'Tampered\')');
        } else if (String.isNotBlank(status)) {
            filters.add('Status__c = :status');
            binds.put('status', status);
        }
        if (integrity == 'Not_Checked') {
            filters.add('(Integrity__c = null OR Integrity__c = \'Not_Checked\')');
        } else if (String.isNotBlank(integrity)) {
            filters.add('Integrity__c = :integrity');
            binds.put('integrity', integrity);
        }
        if (String.isNotBlank(agent)) {
            filters.add('Agent_Id__c LIKE :agent');
            binds.put('agent', '%' + agent.trim() + '%');
        }
        String soql = 'SELECT Id, Name, Agent_Id__c, Status__c, Integrity__c, Mode__c, Start_Time__c, Last_Activity__c, '
            + 'Started_By__r.Name, Record_Count__c, Related_Record_Id__c, Related_Object__c, Agent_Version__c '
            + 'FROM Agent_Audit_Session__c'
            + (filters.isEmpty() ? '' : ' WHERE ' + String.join(filters, ' AND '))
            + ' ORDER BY Start_Time__c DESC LIMIT :rowLimit';

        List<RunRow> rows = new List<RunRow>();
        for (Agent_Audit_Session__c r : (List<Agent_Audit_Session__c>) Database.queryWithBinds(soql, binds, AccessLevel.SYSTEM_MODE)) {
            RunRow row = new RunRow();
            row.runId = r.Id;
            row.name = r.Name;
            row.agent = r.Agent_Id__c;
            row.status = AgentAuditRecorder.isClosed(r.Status__c) && r.Status__c != AgentAuditRecorder.STATUS_INCOMPLETE
                ? AgentAuditRecorder.STATUS_CLOSED : r.Status__c;
            row.integrity = r.Integrity__c == null || r.Integrity__c == 'Not_Checked' ? 'Not checked' : r.Integrity__c;
            row.mode = r.Mode__c == null ? 'Tamper-Evident' : r.Mode__c.replace('_', ' ');
            row.startTime = r.Start_Time__c;
            row.lastActivity = r.Last_Activity__c;
            row.startedBy = r.Started_By__r == null ? null : r.Started_By__r.Name;
            row.steps = r.Record_Count__c == null ? 0 : r.Record_Count__c.intValue();
            row.relatedRecordId = r.Related_Record_Id__c;
            row.relatedObject = r.Related_Object__c;
            row.agentVersion = r.Agent_Version__c;
            rows.add(row);
        }
        return rows;
    }
}
