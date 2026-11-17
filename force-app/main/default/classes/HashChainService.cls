/**
 * HashChainService
 *
 * SHA-256 hashing and hash-chain checks for AgentLedger entries.
 *
 * Two record-hash versions:
 *
 *   v2 (new runs): SHA-256("agentledger/record-hash/v2\n" + RFC 8785 canonical
 *   JSON of the entry), the same rule as hashActionRecordV2 in the open-source
 *   library, so exported runs verify with the npm and PyPI verifiers. The
 *   timestamp is the stored text (Timestamp_Text__c), never a formatted
 *   DateTime, so the hash does not depend on who verifies or where.
 *
 *   v1 (runs recorded before v2): a JSON array of the content fields. Its
 *   timestamp was formatted in the recording user's time zone, so it is
 *   recomputed in the time zone of the user who created the entry.
 */
public with sharing class HashChainService {

    public static final String HASH_V1 = 'v1';
    public static final String HASH_V2 = 'v2';
    public static final String RECORD_HASH_V2_TAG = 'agentledger/record-hash/v2\n';
    private static final String V1_TIMESTAMP_FORMAT = 'yyyy-MM-dd HH:mm:ss';

    /**
     * SHA-256 of a string's UTF-8 bytes, as 64 lowercase hex characters.
     */
    public static String sha256(String data) {
        return EncodingUtil.convertToHex(Crypto.generateDigest('SHA-256', Blob.valueOf(data)));
    }

    /** The hash version of a run: v2, or v1 when blank (runs recorded before v2). */
    public static String versionOf(String hashVersion) {
        return hashVersion == HASH_V2 ? HASH_V2 : HASH_V1;
    }

    // ── v2 ──

    /**
     * The v2 hash of an entry.
     *
     * @param record      the entry, with Entry_Id__c and Timestamp_Text__c set
     * @param sessionUuid the run's Session_Id__c
     */
    public static String hashEntryV2(Agent_Audit_Record__c record, String sessionUuid) {
        return sha256(RECORD_HASH_V2_TAG + AgentLedgerCanonical.serialize(entryContentV2(record, sessionUuid)));
    }

    /**
     * The content the v2 hash covers, shaped as a record of the open-source
     * library: id, sessionId, sequenceNumber, timestamp, agentId, actionType,
     * input, output, reasoning, metadata, previousHash. agentId, reasoning and
     * metadata are left out when empty; previousHash is null for the first entry.
     */
    public static Map<String, Object> entryContentV2(Agent_Audit_Record__c record, String sessionUuid) {
        Map<String, Object> input = new Map<String, Object>();
        if (record.Input_Context__c != null) {
            input.put('context', record.Input_Context__c);
        }
        Map<String, Object> output = new Map<String, Object>();
        if (record.Output_Result__c != null) {
            output.put('result', record.Output_Result__c);
        }

        Map<String, Object> metadata = new Map<String, Object>();
        putIfNotNull(metadata, 'summary', record.Summary__c);
        putIfNotNull(metadata, 'targetRecordId', record.Target_Record_Id__c);
        putIfNotNull(metadata, 'targetObject', record.Target_Object__c);
        putIfNotNull(metadata, 'fieldChanges', record.Field_Changes__c);
        putIfNotNull(metadata, 'captureMethod', record.Capture_Method__c);
        if (record.Turn_Number__c != null) {
            metadata.put('turnNumber', record.Turn_Number__c.intValue());
        }
        putIfNotNull(metadata, 'agentVersion', record.Agent_Version__c);
        putIfNotNull(metadata, 'instructionsHash', record.Instructions_Hash__c);
        putIfNotNull(metadata, 'policyReference', record.Policy_Reference__c);
        putIfNotNull(metadata, 'policyHash', record.Policy_Hash__c);

        Map<String, Object> content = new Map<String, Object>{
            'id' => record.Entry_Id__c,
            'sessionId' => sessionUuid,
            'sequenceNumber' => record.Sequence_Number__c == null ? null : record.Sequence_Number__c.intValue(),
            'timestamp' => record.Timestamp_Text__c,
            'actionType' => record.Action_Type__c,
            'input' => input,
            'output' => output,
            'previousHash' => record.Previous_Hash__c
        };
        putIfNotNull(content, 'agentId', record.Agent_Id__c);
        putIfNotNull(content, 'reasoning', record.Reasoning__c);
        if (!metadata.isEmpty()) {
            content.put('metadata', metadata);
        }
        return content;
    }

    // ── v1 (legacy) ──

    /**
     * The v1 hash of an entry, with the timestamp in the running user's time
     * zone. Kept for compatibility; verification uses the overload below.
     */
    public static String hashActionRecord(Agent_Audit_Record__c record) {
        return hashActionRecord(record, UserInfo.getTimeZone().getID());
    }

    /**
     * The v1 hash of an entry, with the timestamp formatted in the given time
     * zone: the time zone of the user who recorded it.
     */
    public static String hashActionRecord(Agent_Audit_Record__c record, String timeZoneSidKey) {
        String ts = record.Action_Timestamp__c == null
            ? ''
            : record.Action_Timestamp__c.format(V1_TIMESTAMP_FORMAT, timeZoneSidKey);
        List<String> parts = new List<String>{
            safeString(record.Audit_Session__c),
            String.valueOf(record.Sequence_Number__c != null ? record.Sequence_Number__c.intValue() : 0),
            ts,
            safeString(record.Agent_Id__c),
            safeString(record.Action_Type__c),
            safeString(record.Input_Context__c),
            safeString(record.Output_Result__c),
            safeString(record.Reasoning__c),
            safeString(record.Previous_Hash__c)
        };
        return sha256(JSON.serialize(parts));
    }

    /** The time zone v1 hashes of this entry use: its creator's, else the running user's. */
    public static String v1TimeZone(Agent_Audit_Record__c record) {
        try {
            if (record.CreatedBy != null && record.CreatedBy.TimeZoneSidKey != null) {
                return record.CreatedBy.TimeZoneSidKey;
            }
        } catch (SObjectException e) {
            // CreatedBy was not queried; fall through.
        }
        return UserInfo.getTimeZone().getID();
    }

    // ── shared ──

    /**
     * Combine two hashes for the v1 Merkle tree: sha256(left + right).
     */
    public static String combineHashes(String leftHash, String rightHash) {
        return sha256(leftHash + rightHash);
    }

    /**
     * Recompute an entry's hash with its run's hash version and compare it to
     * the stored one.
     */
    public static Boolean verifyRecord(Agent_Audit_Record__c record, String hashVersion, String sessionUuid) {
        String recomputed = versionOf(hashVersion) == HASH_V2
            ? hashEntryV2(record, sessionUuid)
            : hashActionRecord(record, v1TimeZone(record));
        return recomputed == record.Record_Hash__c;
    }

    /** v1 check, kept for compatibility. */
    public static Boolean verifyRecord(Agent_Audit_Record__c record) {
        return verifyRecord(record, HASH_V1, null);
    }

    /**
     * Verify a chain of entries ordered by Sequence_Number__c:
     *   1. each entry's hash matches its content
     *   2. each Previous_Hash__c matches the prior entry's hash
     *   3. sequence numbers run from 0 without gaps
     *   4. the first entry has no previous hash
     */
    public static VerificationResult verifyChain(List<Agent_Audit_Record__c> records, String hashVersion, String sessionUuid) {
        VerificationResult result = new VerificationResult();
        result.valid = true;
        result.errors = new List<String>();
        result.recordsChecked = records.size();

        if (records.isEmpty()) {
            return result;
        }

        if (String.isNotBlank(records[0].Previous_Hash__c)) {
            result.valid = false;
            result.errors.add('First record must have null Previous Hash');
        }

        for (Integer i = 0; i < records.size(); i++) {
            Agent_Audit_Record__c record = records[i];
            Integer seq = record.Sequence_Number__c == null ? null : record.Sequence_Number__c.intValue();

            if (seq != i) {
                result.valid = false;
                result.errors.add('Record ' + i + ': sequence number is ' + seq + ', expected ' + i);
            }

            if (!verifyRecord(record, hashVersion, sessionUuid)) {
                result.valid = false;
                result.errors.add('Record ' + i + ' (' + record.Name +
                    '): hash verification failed — content may have been tampered with');
            }

            // The hash covers the timestamp text; the time shown to users is a
            // separate field, so it must agree with the hashed text.
            if (hashVersion == HASH_V2 && !timestampsAgree(record)) {
                result.valid = false;
                result.errors.add('Record ' + i + ' (' + record.Name +
                    '): the displayed time does not match the recorded time');
            }

            if (i > 0 && record.Previous_Hash__c != records[i - 1].Record_Hash__c) {
                result.valid = false;
                result.errors.add('Record ' + i + ' (' + record.Name +
                    '): Previous Hash does not match hash of record ' + (i - 1) + ' — chain is broken');
            }
        }

        return result;
    }

    /** Whether an entry's displayed time is the hashed timestamp text. Entries without both are not checked. */
    @TestVisible
    private static Boolean timestampsAgree(Agent_Audit_Record__c record) {
        if (record.Action_Timestamp__c == null || String.isBlank(record.Timestamp_Text__c)) {
            return true;
        }
        // Date/time fields keep whole seconds; the hashed text also has milliseconds.
        return record.Action_Timestamp__c.formatGmt('yyyy-MM-dd\'T\'HH:mm:ss') == record.Timestamp_Text__c.left(19);
    }

    /** v1 chain check, kept for compatibility. */
    public static VerificationResult verifyChain(List<Agent_Audit_Record__c> records) {
        return verifyChain(records, HASH_V1, null);
    }

    private static void putIfNotNull(Map<String, Object> m, String key, Object value) {
        if (value != null) {
            m.put(key, value);
        }
    }

    private static String safeString(String value) {
        return value != null ? value : '';
    }

    /**
     * Result object for chain verification operations.
     */
    public class VerificationResult {
        @AuraEnabled public Boolean valid;
        @AuraEnabled public List<String> errors;
        @AuraEnabled public Integer recordsChecked;
    }
}
