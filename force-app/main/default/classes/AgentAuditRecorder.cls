/**
 * AgentAuditRecorder
 *
 * The Salesforce-native API for AgentLedger: start a run (session), record
 * entries, seal, and verify.
 *
 * Usage:
 *   Id sessionId = AgentAuditRecorder.startSession('case-escalation-agent', caseId, 'agentforce');
 *   AgentAuditRecorder.recordAction(sessionId, 'case-escalation-agent', 'Decision',
 *       'Priority: High, Status: New', 'Escalate', 'High priority and not yet escalated');
 *   AgentAuditRecorder.sealSession(sessionId);
 *   AgentAuditRecorder.VerifySessionResult result = AgentAuditRecorder.verifySession(sessionId);
 *
 * New runs are hashed with v2 (see HashChainService). Runs recorded before v2
 * keep verifying with v1.
 *
 * A run's Status is its lifecycle (Active, Closed, Incomplete). The result of
 * verification is kept separately in Integrity, with Last Verified At, so a
 * past result is never shown as current.
 */
public with sharing class AgentAuditRecorder {

    public static final String STATUS_ACTIVE = 'Active';
    public static final String STATUS_CLOSED = 'Closed';
    public static final String STATUS_INCOMPLETE = 'Incomplete';
    /** Status values written by earlier versions; read as Closed. */
    private static final Set<String> LEGACY_CLOSED = new Set<String>{ 'Sealed', 'Verified', 'Tampered' };

    /** ISO 8601 UTC with milliseconds, e.g. 2026-11-09T14:03:27.481Z. */
    private static final String TIMESTAMP_FORMAT = 'yyyy-MM-dd\'T\'HH:mm:ss.SSS\'Z\'';

    /**
     * What to record for one entry. Only actionType, agentId and reasoning are
     * required; the rest is optional.
     */
    public class EntryInput {
        public String agentId;
        public String actionType;
        public String inputContext;
        public String outputResult;
        public String reasoning;
        public String summary;
        public String targetRecordId;
        public String targetObject;
        public String fieldChanges;
        public String captureMethod;
        public Integer turnNumber;
    }

    /**
     * Start a new run.
     *
     * @param agentId         Identifier of the agent, e.g. its API name
     * @param relatedRecordId The record the run is about; stored as 18 characters
     * @param platform        Platform identifier
     * @return The Salesforce record Id of the new run
     */
    public static Id startSession(String agentId, String relatedRecordId, String platform) {
        String relatedId = normalizeId(relatedRecordId);
        Agent_Audit_Session__c session = new Agent_Audit_Session__c(
            Session_Id__c = generateUUID(),
            Agent_Id__c = agentId,
            Status__c = STATUS_ACTIVE,
            Integrity__c = 'Not_Checked',
            Start_Time__c = DateTime.now(),
            Related_Record_Id__c = relatedId,
            Related_Object__c = relatedId == null ? null : Id.valueOf(relatedId).getSObjectType().getDescribe().getName(),
            Started_By__c = UserInfo.getUserId(),
            Platform__c = platform,
            Record_Count__c = 0,
            Hash_Version__c = HashChainService.HASH_V2,
            Mode__c = AgentLedgerSettings.forAgent(agentId).mode
        );
        insert session;
        return session.Id;
    }

    /**
     * Record an entry reported by the agent. Kept for the Record Agent Action
     * action and existing callers.
     */
    public static Agent_Audit_Record__c recordAction(
        Id sessionId,
        String agentId,
        String actionType,
        String inputContext,
        String outputResult,
        String reasoning
    ) {
        EntryInput entry = new EntryInput();
        entry.agentId = agentId;
        entry.actionType = actionType;
        entry.inputContext = inputContext;
        entry.outputResult = outputResult;
        entry.reasoning = reasoning;
        entry.captureMethod = 'Reported_by_Agent';
        return recordEntry(sessionId, entry);
    }

    /**
     * Record an entry: compute its hash and chain it to the previous one.
     * The run is locked for the duration, so concurrent calls cannot take the
     * same sequence number.
     */
    public static Agent_Audit_Record__c recordEntry(Id sessionId, EntryInput entry) {
        Agent_Audit_Session__c session = [
            SELECT Id, Status__c, Record_Count__c, Session_Id__c, Hash_Version__c
            FROM Agent_Audit_Session__c
            WHERE Id = :sessionId
            LIMIT 1
            FOR UPDATE
        ];

        if (session.Status__c != STATUS_ACTIVE) {
            throw new MerkleTreeService.AgentLedgerException(
                'Cannot record actions in a ' + session.Status__c +
                ' session. Sessions are immutable once sealed.');
        }

        Integer sequenceNumber = session.Record_Count__c == null ? 0 : session.Record_Count__c.intValue();
        String previousHash = null;
        if (sequenceNumber > 0) {
            List<Agent_Audit_Record__c> prevRecords = [
                SELECT Record_Hash__c
                FROM Agent_Audit_Record__c
                WHERE Audit_Session__c = :sessionId
                ORDER BY Sequence_Number__c DESC
                LIMIT 1
            ];
            if (!prevRecords.isEmpty()) {
                previousHash = prevRecords[0].Record_Hash__c;
            }
        }

        // One clock reading for both the stored timestamp and the hash.
        DateTime now = DateTime.now();

        Agent_Audit_Record__c record = new Agent_Audit_Record__c(
            Audit_Session__c = sessionId,
            Entry_Id__c = generateUUID(),
            Sequence_Number__c = sequenceNumber,
            Action_Timestamp__c = now,
            Timestamp_Text__c = now.formatGmt(TIMESTAMP_FORMAT),
            Agent_Id__c = entry.agentId,
            Action_Type__c = entry.actionType,
            Input_Context__c = entry.inputContext,
            Output_Result__c = entry.outputResult,
            Reasoning__c = entry.reasoning,
            Summary__c = entry.summary,
            Target_Record_Id__c = normalizeId(entry.targetRecordId),
            Target_Object__c = entry.targetObject,
            Field_Changes__c = entry.fieldChanges,
            Capture_Method__c = entry.captureMethod,
            Turn_Number__c = entry.turnNumber,
            Previous_Hash__c = previousHash
        );

        record.Record_Hash__c = HashChainService.versionOf(session.Hash_Version__c) == HashChainService.HASH_V2
            ? HashChainService.hashEntryV2(record, session.Session_Id__c)
            : HashChainService.hashActionRecord(record, UserInfo.getTimeZone().getID());

        AgentLedgerGuard.beginLedgerWrite();
        try {
            insert record;
            session.Record_Count__c = sequenceNumber + 1;
            update session;
        } finally {
            AgentLedgerGuard.endLedgerWrite();
        }

        return record;
    }

    /**
     * Seal an active run: compute the Merkle root and stop further recording.
     *
     * @param sessionId The run's record Id
     * @return The Merkle root
     */
    public static String sealSession(Id sessionId) {
        return MerkleTreeService.sealSession(sessionId);
    }

    /**
     * Verify a run: entry hashes and chain, the Merkle root (once sealed), and
     * the entry count. Uses the run's hash version.
     *
     * @param sessionId The run's record Id
     * @return VerifySessionResult with one check per test
     */
    @AuraEnabled
    public static VerifySessionResult verifySession(Id sessionId) {
        VerifySessionResult result = new VerifySessionResult();
        result.checks = new List<VerificationCheck>();

        Agent_Audit_Session__c session = [
            SELECT Id, Status__c, Merkle_Root__c, Record_Count__c, Session_Id__c, Hash_Version__c
            FROM Agent_Audit_Session__c
            WHERE Id = :sessionId
            LIMIT 1
        ];

        List<Agent_Audit_Record__c> records = queryEntries(sessionId);

        // Check 1: entry hashes and chain linkage
        HashChainService.VerificationResult chainResult =
            HashChainService.verifyChain(records, session.Hash_Version__c, session.Session_Id__c);
        VerificationCheck chainCheck = new VerificationCheck();
        chainCheck.name = 'hash_chain_integrity';
        chainCheck.passed = chainResult.valid;
        chainCheck.detail = chainResult.valid
            ? 'All ' + records.size() + ' records have valid hashes and chain linkage'
            : String.join(chainResult.errors, '; ');
        result.checks.add(chainCheck);

        // Check 2: Merkle root, once sealed
        if (isClosed(session.Status__c)) {
            List<String> hashes = new List<String>();
            for (Agent_Audit_Record__c rec : records) {
                hashes.add(rec.Record_Hash__c);
            }
            String recomputedRoot = MerkleTreeService.computeRoot(hashes, session.Hash_Version__c);
            Boolean rootValid = session.Merkle_Root__c != null && recomputedRoot == session.Merkle_Root__c;

            VerificationCheck rootCheck = new VerificationCheck();
            rootCheck.name = 'merkle_root_integrity';
            rootCheck.passed = rootValid;
            rootCheck.detail = rootValid
                ? 'Merkle root verified: ' + session.Merkle_Root__c.substring(0, 16) + '...'
                : 'Merkle root mismatch: stored ' + shortHash(session.Merkle_Root__c) +
                  ' vs computed ' + shortHash(recomputedRoot);
            result.checks.add(rootCheck);
        }

        // Check 3: entry count
        Integer expected = session.Record_Count__c == null ? 0 : session.Record_Count__c.intValue();
        VerificationCheck countCheck = new VerificationCheck();
        countCheck.name = 'record_count';
        countCheck.passed = records.size() == expected;
        countCheck.detail = 'Session contains ' + records.size() + ' record(s), expected ' + expected;
        result.checks.add(countCheck);

        result.valid = true;
        for (VerificationCheck check : result.checks) {
            if (!check.passed) {
                result.valid = false;
                break;
            }
        }

        result.message = result.valid
            ? 'Session verified successfully. ' + records.size() + ' records, chain intact.'
            : 'Session verification FAILED. See checks for details.';

        // Record the result with its time. Status stays the lifecycle; runs
        // still holding a status from earlier versions move to Closed.
        Agent_Audit_Session__c resultRow = new Agent_Audit_Session__c(
            Id = session.Id,
            Integrity__c = result.valid ? 'Verified' : 'Tampered',
            Last_Verified_At__c = DateTime.now()
        );
        if (LEGACY_CLOSED.contains(session.Status__c)) {
            resultRow.Status__c = STATUS_CLOSED;
        }
        new LedgerWriter().write(resultRow);
        return result;
    }

    /**
     * Get all records for a session, ordered by sequence.
     * Exposed to LWC via AuraEnabled.
     */
    @AuraEnabled(cacheable=true)
    public static List<Agent_Audit_Record__c> getSessionRecords(Id sessionId) {
        return queryEntries(sessionId);
    }

    /**
     * Get session details. Exposed to LWC.
     */
    @AuraEnabled(cacheable=true)
    public static Agent_Audit_Session__c getSession(Id sessionId) {
        return [
            SELECT Id, Name, Session_Id__c, Agent_Id__c, Merkle_Root__c,
                   Status__c, Record_Count__c, Initiator__c, Platform__c,
                   Start_Time__c, End_Time__c, Hash_Version__c,
                   Integrity__c, Last_Verified_At__c, Mode__c, Started_By__c, Related_Object__c
            FROM Agent_Audit_Session__c
            WHERE Id = :sessionId
            LIMIT 1
        ];
    }

    /**
     * Generate a Merkle proof for one record of a run, with the run's hash version.
     */
    @AuraEnabled
    public static MerkleTreeService.MerkleProof generateProof(Id sessionId, Integer recordIndex) {
        Agent_Audit_Session__c session = [
            SELECT Hash_Version__c FROM Agent_Audit_Session__c WHERE Id = :sessionId LIMIT 1
        ];
        List<String> hashes = new List<String>();
        for (Agent_Audit_Record__c rec : [
            SELECT Record_Hash__c
            FROM Agent_Audit_Record__c
            WHERE Audit_Session__c = :sessionId
            ORDER BY Sequence_Number__c ASC
        ]) {
            hashes.add(rec.Record_Hash__c);
        }
        return HashChainService.versionOf(session.Hash_Version__c) == HashChainService.HASH_V2
            ? MerkleTreeService.generateProofV2(hashes, recordIndex)
            : MerkleTreeService.generateProof(hashes, recordIndex);
    }

    /**
     * An 18-character Id for any 15- or 18-character Id; blank stays null.
     * Throws on a value that is not a Salesforce Id.
     */
    public static String normalizeId(String value) {
        if (String.isBlank(value)) {
            return null;
        }
        try {
            return String.valueOf(Id.valueOf(value.trim()));
        } catch (StringException e) {
            throw new MerkleTreeService.AgentLedgerException('Not a valid Salesforce record Id: ' + value);
        }
    }

    private static List<Agent_Audit_Record__c> queryEntries(Id sessionId) {
        return [
            SELECT Id, Name, Audit_Session__c, Sequence_Number__c, Entry_Id__c,
                   Action_Timestamp__c, Timestamp_Text__c, Agent_Id__c, Action_Type__c,
                   Input_Context__c, Output_Result__c, Reasoning__c, Summary__c,
                   Target_Record_Id__c, Target_Object__c, Field_Changes__c,
                   Capture_Method__c, Turn_Number__c,
                   Record_Hash__c, Previous_Hash__c, CreatedBy.TimeZoneSidKey
            FROM Agent_Audit_Record__c
            WHERE Audit_Session__c = :sessionId
            ORDER BY Sequence_Number__c ASC
        ];
    }

    /** A run that can no longer take entries: Closed, Incomplete, or a closed status from earlier versions. */
    public static Boolean isClosed(String status) {
        return status == STATUS_CLOSED || status == STATUS_INCOMPLETE || LEGACY_CLOSED.contains(status);
    }

    /**
     * Writes a verification result. Runs without sharing so anyone who may
     * verify a run can record the result, even without edit access to it.
     */
    private without sharing class LedgerWriter {
        void write(Agent_Audit_Session__c row) {
            AgentLedgerGuard.beginLedgerWrite();
            try {
                update row;
            } finally {
                AgentLedgerGuard.endLedgerWrite();
            }
        }
    }

    private static String shortHash(String h) {
        return h == null ? 'null' : h.substring(0, Math.min(16, h.length())) + '...';
    }

    /**
     * A version 4 UUID.
     */
    private static String generateUUID() {
        String hex = EncodingUtil.convertToHex(Crypto.generateAesKey(128));
        // Version 4 in the 13th digit; RFC 4122 variant (8, 9, a or b) in the 17th.
        String variant = '89ab'.substring(Math.mod('0123456789abcdef'.indexOf(hex.substring(16, 17)), 4),
                                         Math.mod('0123456789abcdef'.indexOf(hex.substring(16, 17)), 4) + 1);
        return hex.substring(0, 8) + '-' +
               hex.substring(8, 12) + '-4' +
               hex.substring(13, 16) + '-' +
               variant + hex.substring(17, 20) + '-' +
               hex.substring(20, 32);
    }

    public class VerifySessionResult {
        @AuraEnabled public Boolean valid;
        @AuraEnabled public String message;
        @AuraEnabled public List<VerificationCheck> checks;
    }

    public class VerificationCheck {
        @AuraEnabled public String name;
        @AuraEnabled public Boolean passed;
        @AuraEnabled public String detail;
    }
}
