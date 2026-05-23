public with sharing class AgentAuditRecorder {

    public static AgentAuditModels.StartSessionResult startSession(AgentAuditModels.StartSessionRequest req) {
        AgentAuditModels.StartSessionResult result = new AgentAuditModels.StartSessionResult();
        result.success = false;

        try {
            if (req == null || String.isBlank(req.agentName)) {
                result.errorMessage = 'agentName is required.';
                return result;
            }

            Agent_Audit_Session__c sessionRecord = new Agent_Audit_Session__c();
            sessionRecord.Session_Id__c = generateUuid();
            sessionRecord.Agent_Name__c = req.agentName;
            sessionRecord.Agent_Type__c = req.agentType;
            sessionRecord.Use_Case__c = req.useCaseLabel;
            sessionRecord.Related_Record_Id__c = req.relatedRecordId;
            sessionRecord.Related_Object_API_Name__c = req.relatedObjectApiName;
            sessionRecord.Platform__c = req.platform;
            sessionRecord.External_Correlation_Id__c = req.externalCorrelationId;
            sessionRecord.Session_Notes__c = req.sessionNotes;
            sessionRecord.Status__c = 'Active';
            sessionRecord.Verification_Status__c = 'Unverified';
            sessionRecord.Start_Time__c = System.now();
            sessionRecord.Record_Count__c = 0;

            insert sessionRecord;

            result.sessionId = sessionRecord.Id;
            result.sessionUUID = sessionRecord.Session_Id__c;
            result.success = true;
            return result;
        } catch (Exception ex) {
            result.errorMessage = ex.getMessage();
            return result;
        }
    }

    public static AgentAuditModels.RecordActionResult recordAction(AgentAuditModels.RecordActionRequest req) {
        AgentAuditModels.RecordActionResult result = new AgentAuditModels.RecordActionResult();
        result.success = false;

        try {
            if (req == null || req.sessionId == null) {
                result.errorMessage = 'sessionId is required.';
                return result;
            }
            if (String.isBlank(req.actionType)) {
                result.errorMessage = 'actionType is required.';
                return result;
            }
            if (String.isBlank(req.actionLabel)) {
                result.errorMessage = 'actionLabel is required.';
                return result;
            }

            Agent_Audit_Session__c sessionRecord = [
                SELECT Id, Record_Count__c, Status__c
                FROM Agent_Audit_Session__c
                WHERE Id = :req.sessionId
                WITH USER_MODE
                LIMIT 1
            ];

            if (sessionRecord.Status__c != 'Active') {
                result.errorMessage = 'Only Active sessions can accept audit records.';
                return result;
            }

            Integer nextSequence = sessionRecord.Record_Count__c == null
                ? 1
                : Integer.valueOf(sessionRecord.Record_Count__c) + 1;

            String previousHash = '';
            if (nextSequence > 1) {
                Agent_Audit_Record__c previousRecord = [
                    SELECT Record_Hash__c
                    FROM Agent_Audit_Record__c
                    WHERE Audit_Session__c = :req.sessionId
                    WITH USER_MODE
                    ORDER BY Sequence_Number__c DESC
                    LIMIT 1
                ];
                previousHash = previousRecord.Record_Hash__c;
            }

            Integer maxLength = getMaxFieldLength();

            String inputContext = truncate(req.inputContext, maxLength);
            String outputResult = truncate(req.outputResult, maxLength);
            String reasoning = truncate(req.reasoning, maxLength);

            String recordHash = HashChainService.computeRecordHash(
                String.valueOf(req.sessionId),
                nextSequence,
                req.actionType,
                req.actionLabel,
                req.decisionCategory,
                req.riskLevel,
                req.targetRecordId,
                req.targetObjectApiName,
                inputContext,
                outputResult,
                reasoning,
                previousHash
            );

            Agent_Audit_Record__c auditRecord = new Agent_Audit_Record__c();
            auditRecord.Audit_Session__c = req.sessionId;
            auditRecord.Sequence_Number__c = nextSequence;
            auditRecord.Action_Type__c = req.actionType;
            auditRecord.Action_Label__c = req.actionLabel;
            auditRecord.Decision_Category__c = req.decisionCategory;
            auditRecord.Risk_Level__c = req.riskLevel;
            auditRecord.Target_Record_Id__c = req.targetRecordId;
            auditRecord.Target_Object_API_Name__c = req.targetObjectApiName;
            auditRecord.Input_Context__c = inputContext;
            auditRecord.Output_Result__c = outputResult;
            auditRecord.Reasoning__c = reasoning;
            auditRecord.Action_Timestamp__c = System.now();
            auditRecord.Previous_Hash__c = previousHash;
            auditRecord.Record_Hash__c = recordHash;

            insert auditRecord;

            sessionRecord.Record_Count__c = nextSequence;
            update sessionRecord;

            result.auditRecordId = auditRecord.Id;
            result.sequenceNumber = nextSequence;
            result.recordHash = recordHash;
            result.success = true;
            return result;
        } catch (Exception ex) {
            result.errorMessage = ex.getMessage();
            return result;
        }
    }

    public static AgentAuditModels.SealSessionResult sealSession(AgentAuditModels.SealSessionRequest req) {
        AgentAuditModels.SealSessionResult result = new AgentAuditModels.SealSessionResult();
        result.success = false;

        try {
            if (req == null || req.sessionId == null) {
                result.errorMessage = 'sessionId is required.';
                return result;
            }

            List<Agent_Audit_Record__c> records = [
                SELECT Id, Record_Hash__c
                FROM Agent_Audit_Record__c
                WHERE Audit_Session__c = :req.sessionId
                WITH USER_MODE
                ORDER BY Sequence_Number__c ASC
            ];

            List<String> leafHashes = new List<String>();
            for (Agent_Audit_Record__c recordItem : records) {
                leafHashes.add(recordItem.Record_Hash__c);
            }

            String merkleRoot = MerkleTreeService.computeMerkleRoot(leafHashes);

            Agent_Audit_Session__c sessionRecord = [
                SELECT Id, Status__c, Record_Count__c, Merkle_Root__c, Verification_Status__c
                FROM Agent_Audit_Session__c
                WHERE Id = :req.sessionId
                WITH USER_MODE
                LIMIT 1
            ];

            sessionRecord.Status__c = 'Sealed';
            sessionRecord.End_Time__c = System.now();
            sessionRecord.Record_Count__c = records.size();
            sessionRecord.Merkle_Root__c = merkleRoot;
            sessionRecord.Verification_Status__c = 'Unverified';
            update sessionRecord;

            result.success = true;
            result.sessionId = sessionRecord.Id;
            result.merkleRoot = merkleRoot;
            result.recordCount = records.size();
            result.verificationStatus = sessionRecord.Verification_Status__c;
            return result;
        } catch (Exception ex) {
            result.errorMessage = ex.getMessage();
            return result;
        }
    }

    public static AgentAuditModels.VerifySessionResult verifySession(AgentAuditModels.VerifySessionRequest req) {
        AgentAuditModels.VerifySessionResult result = new AgentAuditModels.VerifySessionResult();
        result.verified = false;

        try {
            if (req == null || req.sessionId == null) {
                result.verificationStatus = 'Error';
                result.errorMessage = 'sessionId is required.';
                return result;
            }

            Agent_Audit_Session__c sessionRecord = [
                SELECT Id, Merkle_Root__c, Verification_Status__c
                FROM Agent_Audit_Session__c
                WHERE Id = :req.sessionId
                WITH USER_MODE
                LIMIT 1
            ];

            List<Agent_Audit_Record__c> records = [
                SELECT Id, Audit_Session__c, Sequence_Number__c, Action_Type__c, Action_Label__c,
                       Decision_Category__c, Risk_Level__c, Target_Record_Id__c,
                       Target_Object_API_Name__c, Input_Context__c, Output_Result__c,
                       Reasoning__c, Previous_Hash__c, Record_Hash__c
                FROM Agent_Audit_Record__c
                WHERE Audit_Session__c = :req.sessionId
                WITH USER_MODE
                ORDER BY Sequence_Number__c ASC
            ];

            List<String> leafHashes = new List<String>();
            for (Agent_Audit_Record__c recordItem : records) {
                leafHashes.add(recordItem.Record_Hash__c);
            }

            String recomputedRoot = MerkleTreeService.computeMerkleRoot(leafHashes);
            Boolean chainValid = HashChainService.verifyChain(records);
            Boolean rootValid = recomputedRoot == sessionRecord.Merkle_Root__c;

            result.verified = chainValid && rootValid;
            result.verificationStatus = result.verified ? 'Verified' : 'Tampered';
            result.merkleRoot = recomputedRoot;
            result.recordCount = records.size();

            sessionRecord.Verification_Status__c = result.verificationStatus;
            update sessionRecord;

            return result;
        } catch (Exception ex) {
            result.verificationStatus = 'Error';
            result.errorMessage = ex.getMessage();

            try {
                if (req != null && req.sessionId != null) {
                    Agent_Audit_Session__c sessionRecord = new Agent_Audit_Session__c(
                        Id = req.sessionId,
                        Verification_Status__c = 'Error'
                    );
                    update sessionRecord;
                }
            } catch (Exception ignored) {}

            return result;
        }
    }

    private static String generateUuid() {
        return String.valueOf(Crypto.getRandomLong()) + '-' + String.valueOf(DateTime.now().getTime());
    }

    private static Integer getMaxFieldLength() {
        try {
            AgentLedger_Config__mdt config = AgentLedger_Config__mdt.getInstance('Default_Config');
            if (config != null && config.Max_Field_Length__c != null) {
                return Integer.valueOf(config.Max_Field_Length__c);
            }
        } catch (Exception ignored) {}
        return 32768;
    }

    private static String truncate(String value, Integer maxLength) {
        if (value == null) {
            return null;
        }
        if (maxLength == null || maxLength <= 0) {
            maxLength = 32768;
        }
        return value.length() > maxLength ? value.substring(0, maxLength) : value;
    }
}