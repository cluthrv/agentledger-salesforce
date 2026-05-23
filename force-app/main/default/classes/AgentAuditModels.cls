public with sharing class AgentAuditModels {

    public class StartSessionRequest {
        public String agentName;
        public String agentType;
        public String useCaseLabel;
        public String relatedRecordId;
        public String relatedObjectApiName;
        public String platform;
        public String externalCorrelationId;
        public String sessionNotes;
    }

    public class StartSessionResult {
        public Id sessionId;
        public String sessionUUID;
        public Boolean success;
        public String errorMessage;
    }

    public class RecordActionRequest {
        public Id sessionId;
        public String actionType;
        public String actionLabel;
        public String targetRecordId;
        public String targetObjectApiName;
        public String inputContext;
        public String outputResult;
        public String reasoning;
        public String decisionCategory;
        public String riskLevel;
    }

    public class RecordActionResult {
        public Id auditRecordId;
        public Integer sequenceNumber;
        public String recordHash;
        public Boolean success;
        public String errorMessage;
    }

    public class SealSessionRequest {
        public Id sessionId;
    }

    public class SealSessionResult {
        public Boolean success;
        public Id sessionId;
        public String merkleRoot;
        public Integer recordCount;
        public String verificationStatus;
        public String errorMessage;
    }

    public class VerifySessionRequest {
        public Id sessionId;
    }

    public class VerifySessionResult {
        public Boolean verified;
        public String verificationStatus;
        public String merkleRoot;
        public Integer recordCount;
        public String errorMessage;
    }
}
