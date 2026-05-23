@IsTest
private class MerkleTreeServiceTest {
    @IsTest
    static void testSingleLeafRoot() {
        String leaf = HashChainService.hashString('record-1');

        System.assertEquals(leaf, MerkleTreeService.computeMerkleRoot(new List<String>{ leaf }));
    }

    @IsTest
    static void testOddLeafCountDuplicatesLastLeaf() {
        List<String> leaves = new List<String>{
            HashChainService.hashString('record-1'),
            HashChainService.hashString('record-2'),
            HashChainService.hashString('record-3')
        };

        String root = MerkleTreeService.computeMerkleRoot(leaves);

        System.assertEquals(64, root.length());
        System.assert(MerkleTreeService.verifyMerkleRoot(leaves, root));
    }

    @IsTest
    static void testModifiedLeafFailsVerification() {
        List<String> leaves = new List<String>{
            HashChainService.hashString('record-1'),
            HashChainService.hashString('record-2')
        };

        String root = MerkleTreeService.computeMerkleRoot(leaves);

        leaves[1] = HashChainService.hashString('tampered');

        System.assertEquals(false, MerkleTreeService.verifyMerkleRoot(leaves, root));
    }
}
