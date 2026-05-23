public with sharing class MerkleTreeService {
    public static String computeMerkleRoot(List<String> leafHashes) {
        if (leafHashes == null || leafHashes.isEmpty()) {
            return HashChainService.hashString('');
        }

        List<String> currentLevel = new List<String>();
        currentLevel.addAll(leafHashes);

        while (currentLevel.size() > 1) {
            List<String> nextLevel = new List<String>();

            for (Integer i = 0; i < currentLevel.size(); i += 2) {
                String leftHash = currentLevel[i];
                String rightHash = (i + 1 < currentLevel.size()) ? currentLevel[i + 1] : leftHash;
                nextLevel.add(HashChainService.hashString(leftHash + rightHash));
            }

            currentLevel = nextLevel;
        }

        return currentLevel[0];
    }

    public static Boolean verifyMerkleRoot(List<String> leafHashes, String storedRoot) {
        if (String.isBlank(storedRoot)) {
            return false;
        }

        return computeMerkleRoot(leafHashes) == storedRoot;
    }
}
