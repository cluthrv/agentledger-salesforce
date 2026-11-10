/**
 * MerkleTreeService
 *
 * Builds Merkle trees from Action Record hashes, computes root hashes,
 * generates proofs, and verifies proofs.
 *
 * Designed to work within Salesforce governor limits. Tree construction
 * is performed in-memory using Lists rather than recursive structures.
 */
public with sharing class MerkleTreeService {

    /**
     * Compute the Merkle root from a list of Action Record hashes.
     * If the number of hashes is odd, the last hash is duplicated
     * to create a balanced tree.
     *
     * @param hashes List of SHA-256 hashes from Action Records
     * @return The Merkle root hash, or null if input is empty
     */
    public static String computeMerkleRoot(List<String> hashes) {
        if (hashes == null || hashes.isEmpty()) {
            return null;
        }

        // Create leaf nodes by hashing each record hash
        List<String> currentLevel = new List<String>();
        for (String h : hashes) {
            currentLevel.add(HashChainService.sha256(h));
        }

        // Build tree bottom-up
        while (currentLevel.size() > 1) {
            List<String> nextLevel = new List<String>();

            for (Integer i = 0; i < currentLevel.size(); i += 2) {
                String left = currentLevel[i];
                // If odd number, duplicate the last node
                String right = (i + 1 < currentLevel.size())
                    ? currentLevel[i + 1]
                    : currentLevel[i];

                nextLevel.add(HashChainService.combineHashes(left, right));
            }

            currentLevel = nextLevel;
        }

        return currentLevel[0];
    }

    /**
     * Generate a Merkle proof for a specific record.
     * The proof contains sibling hashes needed to recompute
     * the root from the target leaf.
     *
     * @param hashes All Action Record hashes in the session
     * @param recordIndex Index of the record to prove
     * @return MerkleProof object, or null if index is out of bounds
     */
    public static MerkleProof generateProof(List<String> hashes, Integer recordIndex) {
        if (hashes == null || hashes.isEmpty() ||
            recordIndex < 0 || recordIndex >= hashes.size()) {
            return null;
        }

        String root = computeMerkleRoot(hashes);
        if (root == null) {
            return null;
        }

        // Build leaf hashes
        List<String> leafHashes = new List<String>();
        for (String h : hashes) {
            leafHashes.add(HashChainService.sha256(h));
        }

        List<ProofSibling> siblings = new List<ProofSibling>();
        List<String> currentLevel = new List<String>(leafHashes);
        Integer targetIndex = recordIndex;

        while (currentLevel.size() > 1) {
            List<String> nextLevel = new List<String>();

            for (Integer i = 0; i < currentLevel.size(); i += 2) {
                String left = currentLevel[i];
                String right = (i + 1 < currentLevel.size())
                    ? currentLevel[i + 1]
                    : currentLevel[i];

                // If target is in this pair, collect sibling
                if (i == targetIndex || i + 1 == targetIndex) {
                    ProofSibling sibling = new ProofSibling();
                    if (Math.mod(targetIndex, 2) == 0) {
                        sibling.hash = right;
                        sibling.position = 'right';
                    } else {
                        sibling.hash = left;
                        sibling.position = 'left';
                    }
                    siblings.add(sibling);
                }

                nextLevel.add(HashChainService.combineHashes(left, right));
            }

            currentLevel = nextLevel;
            targetIndex = targetIndex / 2;
        }

        MerkleProof proof = new MerkleProof();
        proof.recordIndex = recordIndex;
        proof.recordHash = hashes[recordIndex];
        proof.siblings = siblings;
        proof.root = root;

        return proof;
    }

    /**
     * Verify a Merkle proof against a claimed root hash.
     *
     * @param proof The MerkleProof to verify
     * @return true if the proof is valid
     */
    public static Boolean verifyProof(MerkleProof proof) {
        if (proof == null || proof.siblings == null) {
            return false;
        }

        String currentHash = HashChainService.sha256(proof.recordHash);

        for (ProofSibling sibling : proof.siblings) {
            if (sibling.position == 'right') {
                currentHash = HashChainService.combineHashes(currentHash, sibling.hash);
            } else {
                currentHash = HashChainService.combineHashes(sibling.hash, currentHash);
            }
        }

        return currentHash == proof.root;
    }

    /**
     * Seal a session by computing the Merkle root from its records.
     * Updates the session record with the root hash and sealed status.
     *
     * @param sessionId The Salesforce record Id of the Agent_Audit_Session__c
     * @return The computed Merkle root hash
     */
    public static String sealSession(Id sessionId) {
        // Lock the run so a concurrent record or seal cannot interleave.
        Agent_Audit_Session__c current = [
            SELECT Id, Status__c, Hash_Version__c
            FROM Agent_Audit_Session__c
            WHERE Id = :sessionId
            LIMIT 1
            FOR UPDATE
        ];
        // Only an active run can be sealed. Re-sealing a closed run would
        // recompute the root over whatever the entries hold now, which would
        // hide any change made since the original seal.
        if (current.Status__c != AgentAuditRecorder.STATUS_ACTIVE) {
            throw new AgentLedgerException('Cannot seal a ' + current.Status__c + ' session. Only an active session can be sealed.');
        }

        List<Agent_Audit_Record__c> records = [
            SELECT Record_Hash__c
            FROM Agent_Audit_Record__c
            WHERE Audit_Session__c = :sessionId
            ORDER BY Sequence_Number__c ASC
        ];

        if (records.isEmpty()) {
            throw new AgentLedgerException('Cannot seal an empty session.');
        }

        List<String> hashes = new List<String>();
        for (Agent_Audit_Record__c record : records) {
            hashes.add(record.Record_Hash__c);
        }

        String merkleRoot = computeRoot(hashes, current.Hash_Version__c);

        Agent_Audit_Session__c session = new Agent_Audit_Session__c(
            Id = sessionId,
            Merkle_Root__c = merkleRoot,
            Status__c = AgentAuditRecorder.STATUS_CLOSED,
            End_Time__c = DateTime.now(),
            Record_Count__c = records.size()
        );
        AgentLedgerGuard.beginLedgerWrite();
        try {
            update session;
        } finally {
            AgentLedgerGuard.endLedgerWrite();
        }

        return merkleRoot;
    }

    // ── v2: RFC 6962 style, the same tree as computeMerkleRootV2 in the open-source library ──
    //   leaf = SHA-256(0x00 || record hash bytes)
    //   node = SHA-256(0x01 || left bytes || right bytes)
    // An odd node at the end of a level is carried up unchanged, never duplicated.

    /** The root for a run's hash version: v2, or v1 (the tree above) when blank. */
    public static String computeRoot(List<String> hashes, String hashVersion) {
        return HashChainService.versionOf(hashVersion) == HashChainService.HASH_V2
            ? computeMerkleRootV2(hashes)
            : computeMerkleRoot(hashes);
    }

    public static String merkleLeafV2(String recordHash) {
        return digestHex('00' + requireHash(recordHash));
    }

    public static String merkleNodeV2(String left, String right) {
        return digestHex('01' + requireHash(left) + requireHash(right));
    }

    public static String computeMerkleRootV2(List<String> hashes) {
        if (hashes == null || hashes.isEmpty()) {
            return null;
        }
        List<String> level = new List<String>();
        for (String h : hashes) {
            level.add(merkleLeafV2(h));
        }
        while (level.size() > 1) {
            level = nextLevelV2(level);
        }
        return level[0];
    }

    /**
     * A v2 proof for one record. A level where the record's node is carried up
     * adds no sibling.
     */
    public static MerkleProof generateProofV2(List<String> hashes, Integer recordIndex) {
        if (hashes == null || hashes.isEmpty() || recordIndex == null ||
            recordIndex < 0 || recordIndex >= hashes.size()) {
            return null;
        }
        List<String> level = new List<String>();
        for (String h : hashes) {
            level.add(merkleLeafV2(h));
        }
        List<ProofSibling> siblings = new List<ProofSibling>();
        Integer index = recordIndex;
        while (level.size() > 1) {
            Integer pair = Math.mod(index, 2) == 0 ? index + 1 : index - 1;
            if (pair < level.size()) {
                ProofSibling sibling = new ProofSibling();
                sibling.hash = level[pair];
                sibling.position = Math.mod(index, 2) == 0 ? 'right' : 'left';
                siblings.add(sibling);
            }
            level = nextLevelV2(level);
            index = index / 2;
        }
        MerkleProof proof = new MerkleProof();
        proof.recordIndex = recordIndex;
        proof.recordHash = hashes[recordIndex];
        proof.siblings = siblings;
        proof.root = level[0];
        return proof;
    }

    public static Boolean verifyProofV2(MerkleProof proof) {
        if (proof == null || proof.siblings == null || proof.recordHash == null) {
            return false;
        }
        try {
            String current = merkleLeafV2(proof.recordHash);
            for (ProofSibling sibling : proof.siblings) {
                current = sibling.position == 'right'
                    ? merkleNodeV2(current, sibling.hash)
                    : merkleNodeV2(sibling.hash, current);
            }
            return current == proof.root;
        } catch (AgentLedgerException e) {
            return false;
        }
    }

    private static List<String> nextLevelV2(List<String> level) {
        List<String> next = new List<String>();
        for (Integer i = 0; i < level.size(); i += 2) {
            next.add(i + 1 < level.size() ? merkleNodeV2(level[i], level[i + 1]) : level[i]);
        }
        return next;
    }

    private static String digestHex(String hexBytes) {
        return EncodingUtil.convertToHex(Crypto.generateDigest('SHA-256', EncodingUtil.convertFromHex(hexBytes)));
    }

    private static String requireHash(String h) {
        if (h == null || !Pattern.matches('[0-9a-f]{64}', h)) {
            throw new AgentLedgerException('Not a SHA-256 hex hash: ' + h);
        }
        return h;
    }

    /**
     * Represents a Merkle proof for a single record.
     */
    public class MerkleProof {
        @AuraEnabled public Integer recordIndex;
        @AuraEnabled public String recordHash;
        @AuraEnabled public List<ProofSibling> siblings;
        @AuraEnabled public String root;
    }

    /**
     * A sibling hash in a Merkle proof path.
     */
    public class ProofSibling {
        @AuraEnabled public String hash;
        @AuraEnabled public String position; // 'left' or 'right'
    }

    public class AgentLedgerException extends Exception {}
}