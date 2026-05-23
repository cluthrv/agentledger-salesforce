public with sharing class AgentAuditQueryService {

    public class SessionFilterRequest {
        @AuraEnabled public String agentName;
        @AuraEnabled public String objectApiName;
        @AuraEnabled public String status;
        @AuraEnabled public String verificationStatus;
        @AuraEnabled public Date startDate;
        @AuraEnabled public Date endDate;
        @AuraEnabled public Integer limitCount;
    }

    public class LwcVerifyResult {
        @AuraEnabled public Boolean verified;
        @AuraEnabled public String verificationStatus;
        @AuraEnabled public String merkleRoot;
        @AuraEnabled public Integer recordCount;
        @AuraEnabled public String errorMessage;
    }

    @AuraEnabled(cacheable=true)
    public static List<Agent_Audit_Session__c> getSessionsByRecord(String recordId, Integer limitCount) {
        Integer safeLimit = normalizeLimit(limitCount);

        return [
            SELECT Id, Name, Session_Id__c, Agent_Name__c, Agent_Type__c, Use_Case__c,
                   External_Correlation_Id__c, Status__c, Start_Time__c, End_Time__c,
                   Record_Count__c, Merkle_Root__c, Verification_Status__c,
                   Related_Record_Id__c, Related_Object_API_Name__c, Platform__c
            FROM Agent_Audit_Session__c
            WHERE Related_Record_Id__c = :recordId
            WITH USER_MODE
            ORDER BY Start_Time__c DESC
            LIMIT :safeLimit
        ];
    }

    @AuraEnabled(cacheable=true)
    public static List<Agent_Audit_Record__c> getRecordsBySession(Id sessionId) {
        return [
            SELECT Id, Name, Audit_Session__c, Sequence_Number__c, Action_Type__c,
                   Action_Label__c, Decision_Category__c, Risk_Level__c,
                   Target_Record_Id__c, Target_Object_API_Name__c,
                   Input_Context__c, Output_Result__c, Reasoning__c,
                   Action_Timestamp__c, Previous_Hash__c, Record_Hash__c
            FROM Agent_Audit_Record__c
            WHERE Audit_Session__c = :sessionId
            WITH USER_MODE
            ORDER BY Sequence_Number__c ASC
        ];
    }

    @AuraEnabled(cacheable=true)
    public static Agent_Audit_Session__c getSessionSummary(Id sessionId) {
        return [
            SELECT Id, Name, Session_Id__c, Agent_Name__c, Agent_Type__c, Use_Case__c,
                   External_Correlation_Id__c, Status__c, Start_Time__c, End_Time__c,
                   Record_Count__c, Merkle_Root__c, Verification_Status__c,
                   Related_Record_Id__c, Related_Object_API_Name__c, Initiator__c,
                   Platform__c, Error_Message__c, Seal_Error__c, Session_Notes__c
            FROM Agent_Audit_Session__c
            WHERE Id = :sessionId
            WITH USER_MODE
            LIMIT 1
        ];
    }

    @AuraEnabled(cacheable=true)
    public static List<Agent_Audit_Session__c> getAllSessionsFiltered(SessionFilterRequest req) {
        Integer safeLimit = normalizeLimit(req == null ? null : req.limitCount);

        List<Agent_Audit_Session__c> candidates = [
            SELECT Id, Name, Session_Id__c, Agent_Name__c, Agent_Type__c, Use_Case__c,
                   External_Correlation_Id__c, Status__c, Start_Time__c, End_Time__c,
                   Record_Count__c, Merkle_Root__c, Verification_Status__c,
                   Related_Record_Id__c, Related_Object_API_Name__c, Platform__c
            FROM Agent_Audit_Session__c
            WITH USER_MODE
            ORDER BY Start_Time__c DESC
            LIMIT 500
        ];

        List<Agent_Audit_Session__c> results = new List<Agent_Audit_Session__c>();

        for (Agent_Audit_Session__c sessionRecord : candidates) {
            if (!matchesFilter(sessionRecord, req)) {
                continue;
            }

            results.add(sessionRecord);

            if (results.size() >= safeLimit) {
                break;
            }
        }

        return results;
    }

    @AuraEnabled
    public static LwcVerifyResult verifySessionForLwc(Id sessionId) {
        AgentAuditModels.VerifySessionRequest req = new AgentAuditModels.VerifySessionRequest();
        req.sessionId = sessionId;

        AgentAuditModels.VerifySessionResult rawResult = AgentAuditRecorder.verifySession(req);

        LwcVerifyResult result = new LwcVerifyResult();
        result.verified = rawResult.verified;
        result.verificationStatus = rawResult.verificationStatus;
        result.merkleRoot = rawResult.merkleRoot;
        result.recordCount = rawResult.recordCount;
        result.errorMessage = rawResult.errorMessage;

        return result;
    }

    private static Boolean matchesFilter(Agent_Audit_Session__c sessionRecord, SessionFilterRequest req) {
        if (req == null) {
            return true;
        }

        if (!String.isBlank(req.agentName)) {
            String agentName = sessionRecord.Agent_Name__c == null
                ? ''
                : sessionRecord.Agent_Name__c.toLowerCase();

            if (!agentName.contains(req.agentName.toLowerCase())) {
                return false;
            }
        }

        if (!String.isBlank(req.objectApiName)
            && sessionRecord.Related_Object_API_Name__c != req.objectApiName) {
            return false;
        }

        if (!String.isBlank(req.status)
            && sessionRecord.Status__c != req.status) {
            return false;
        }

        if (!String.isBlank(req.verificationStatus)
            && sessionRecord.Verification_Status__c != req.verificationStatus) {
            return false;
        }

        if (req.startDate != null && sessionRecord.Start_Time__c != null) {
            Date sessionDate = sessionRecord.Start_Time__c.date();
            if (sessionDate < req.startDate) {
                return false;
            }
        }

        if (req.endDate != null && sessionRecord.Start_Time__c != null) {
            Date sessionDate = sessionRecord.Start_Time__c.date();
            if (sessionDate > req.endDate) {
                return false;
            }
        }

        return true;
    }

    private static Integer normalizeLimit(Integer limitCount) {
        if (limitCount == null || limitCount <= 0) {
            return 50;
        }

        if (limitCount > 500) {
            return 500;
        }

        return limitCount;
    }
}