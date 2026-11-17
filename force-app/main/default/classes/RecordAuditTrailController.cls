/**
 * RecordAuditTrailController
 *
 * Provides data for the recordAuditTrail LWC component that sits on
 * any Salesforce record page (Opportunity, Account, Case, etc.) and
 * displays the AgentLedger audit trail for that specific record.
 *
 * Runs are private, so this class reads them without sharing, and only after
 * confirming the user can read the record: whoever may see a record may see
 * what agents did to it.
 */
public without sharing class RecordAuditTrailController {

    /**
     * Get all audit sessions related to a specific Salesforce record.
     * @param recordId The Salesforce record Id (e.g., an Opportunity Id)
     * @return List of sessions with their audit records
     */
    @AuraEnabled(cacheable=true)
    public static List<SessionSummary> getSessionsForRecord(String recordId) {
        List<SessionSummary> summaries = new List<SessionSummary>();
        if (String.isBlank(recordId)) {
            return summaries;
        }
        Id asId;
        try {
            asId = Id.valueOf(recordId);
        } catch (StringException e) {
            return summaries;
        }
        if (!AgentLedgerAccess.canReadRecord(asId)) {
            return summaries;
        }

        // Runs store 18-character Ids; older runs may hold the 15-character form.
        Set<String> idForms = new Set<String>{ recordId };
        try {
            String full = String.valueOf(Id.valueOf(recordId));
            idForms.add(full);
            idForms.add(full.left(15));
        } catch (StringException e) {
            // Not an Id: match the value as given.
        }

        List<Agent_Audit_Session__c> sessions = [
            SELECT Id, Name, Session_Id__c, Agent_Id__c, Merkle_Root__c,
                   Status__c, Record_Count__c, Initiator__c, Platform__c,
                   Start_Time__c, End_Time__c, Related_Record_Id__c,
                   Integrity__c, Last_Verified_At__c
            FROM Agent_Audit_Session__c
            WHERE Related_Record_Id__c IN :idForms
            ORDER BY Start_Time__c DESC
        ];

        // All entries for these runs in one query.
        Map<Id, List<Agent_Audit_Record__c>> entriesBySession = new Map<Id, List<Agent_Audit_Record__c>>();
        for (Agent_Audit_Session__c session : sessions) {
            entriesBySession.put(session.Id, new List<Agent_Audit_Record__c>());
        }
        for (Agent_Audit_Record__c rec : [
            SELECT Id, Name, Audit_Session__c, Sequence_Number__c, Action_Timestamp__c,
                   Agent_Id__c, Action_Type__c, Reasoning__c, Record_Hash__c, Previous_Hash__c, Target_Record_Id__c
            FROM Agent_Audit_Record__c
            WHERE Audit_Session__c IN :entriesBySession.keySet()
            ORDER BY Audit_Session__c, Sequence_Number__c ASC
        ]) {
            entriesBySession.get(rec.Audit_Session__c).add(rec);
        }

        // A run can touch several records: the reasoning of a step on a record
        // the user cannot read is not returned.
        Set<String> otherRecords = new Set<String>();
        for (List<Agent_Audit_Record__c> recs : entriesBySession.values()) {
            for (Agent_Audit_Record__c rec : recs) {
                if (String.isNotBlank(rec.Target_Record_Id__c) && !idForms.contains(rec.Target_Record_Id__c)) {
                    otherRecords.add(rec.Target_Record_Id__c);
                }
            }
        }
        Set<String> readable = AgentLedgerAccess.readableRecords(otherRecords);

        for (Agent_Audit_Session__c session : sessions) {
            SessionSummary summary = new SessionSummary();
            summary.sessionId = session.Id;
            summary.sessionName = session.Name;
            summary.agentId = session.Agent_Id__c;
            summary.merkleRoot = session.Merkle_Root__c;
            summary.status = session.Status__c;
            summary.recordCount = Integer.valueOf(session.Record_Count__c);
            summary.initiator = session.Initiator__c;
            summary.startTime = session.Start_Time__c;
            summary.endTime = session.End_Time__c;
            summary.closed = AgentAuditRecorder.isClosed(session.Status__c);
            summary.lifecycle = summary.closed ? AgentAuditRecorder.STATUS_CLOSED : session.Status__c;
            if (session.Status__c == AgentAuditRecorder.STATUS_INCOMPLETE) {
                summary.lifecycle = AgentAuditRecorder.STATUS_INCOMPLETE;
            }
            summary.integrity = session.Integrity__c;
            summary.lastVerifiedAt = session.Last_Verified_At__c;

            summary.records = new List<AuditRecordInfo>();
            for (Agent_Audit_Record__c rec : entriesBySession.get(session.Id)) {
                AuditRecordInfo info = new AuditRecordInfo();
                info.recordId = rec.Id;
                info.sequenceNumber = Integer.valueOf(rec.Sequence_Number__c);
                info.actionType = rec.Action_Type__c;
                Boolean restricted = String.isNotBlank(rec.Target_Record_Id__c)
                    && !idForms.contains(rec.Target_Record_Id__c) && !readable.contains(rec.Target_Record_Id__c);
                info.reasoning = restricted ? AgentLedgerTimelineController.RESTRICTED_SUMMARY : rec.Reasoning__c;
                info.recordHash = rec.Record_Hash__c;
                info.previousHash = rec.Previous_Hash__c;
                info.timestamp = rec.Action_Timestamp__c;
                summary.records.add(info);
            }

            summaries.add(summary);
        }

        return summaries;
    }

    /**
     * Verify a specific session from the record page.
     */
    @AuraEnabled
    public static AgentAuditRecorder.VerifySessionResult verifySessionFromRecord(Id sessionId) {
        return AgentAuditRecorder.verifySession(sessionId);
    }

    public class SessionSummary {
        @AuraEnabled public Id sessionId;
        @AuraEnabled public String sessionName;
        @AuraEnabled public String agentId;
        @AuraEnabled public String merkleRoot;
        @AuraEnabled public String status;
        @AuraEnabled public Integer recordCount;
        @AuraEnabled public String initiator;
        @AuraEnabled public DateTime startTime;
        @AuraEnabled public DateTime endTime;
        @AuraEnabled public Boolean closed;
        @AuraEnabled public String lifecycle;
        @AuraEnabled public String integrity;
        @AuraEnabled public DateTime lastVerifiedAt;
        @AuraEnabled public List<AuditRecordInfo> records;
    }

    public class AuditRecordInfo {
        @AuraEnabled public Id recordId;
        @AuraEnabled public Integer sequenceNumber;
        @AuraEnabled public String actionType;
        @AuraEnabled public String reasoning;
        @AuraEnabled public String recordHash;
        @AuraEnabled public String previousHash;
        @AuraEnabled public DateTime timestamp;
    }
}