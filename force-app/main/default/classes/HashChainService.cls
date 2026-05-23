public with sharing class HashChainService {
    public static String hashString(String input) {
        if (input == null) {
            input = '';
        }
        Blob digest = Crypto.generateDigest('SHA-256', Blob.valueOf(input));
        return EncodingUtil.convertToHex(digest).toLowerCase();
    }

    public static String computeRecordHash(
        String sessionId,
        Integer seqNum,
        String actionType,
        String actionLabel,
        String decisionCategory,
        String riskLevel,
        String targetRecordId,
        String targetObjectApiName,
        String inputContext,
        String outputResult,
        String reasoning,
        String previousHash
    ) {
        String hashInput =
            safe(sessionId) + '|' +
            String.valueOf(seqNum) + '|' +
            safe(actionType) + '|' +
            safe(actionLabel) + '|' +
            safe(decisionCategory) + '|' +
            safe(riskLevel) + '|' +
            safe(targetRecordId) + '|' +
            safe(targetObjectApiName) + '|' +
            safe(inputContext) + '|' +
            safe(outputResult) + '|' +
            safe(reasoning) + '|' +
            safe(previousHash);

        return hashString(hashInput);
    }

    public static Boolean verifyChain(List<Agent_Audit_Record__c> records) {
        if (records == null || records.isEmpty()) {
            return false;
        }

        String expectedPreviousHash = '';

        for (Agent_Audit_Record__c recordItem : records) {
            if (safe(recordItem.Previous_Hash__c) != expectedPreviousHash) {
                return false;
            }

            String recomputedHash = computeRecordHash(
                String.valueOf(recordItem.Audit_Session__c),
                Integer.valueOf(recordItem.Sequence_Number__c),
                recordItem.Action_Type__c,
                recordItem.Action_Label__c,
                recordItem.Decision_Category__c,
                recordItem.Risk_Level__c,
                recordItem.Target_Record_Id__c,
                recordItem.Target_Object_API_Name__c,
                recordItem.Input_Context__c,
                recordItem.Output_Result__c,
                recordItem.Reasoning__c,
                recordItem.Previous_Hash__c
            );

            if (safe(recordItem.Record_Hash__c) != recomputedHash) {
                return false;
            }

            expectedPreviousHash = recordItem.Record_Hash__c;
        }

        return true;
    }

    private static String safe(String value) {
        return value == null ? '' : value;
    }
}