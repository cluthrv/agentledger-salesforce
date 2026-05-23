@IsTest
private class HashChainServiceTest {
    @IsTest
    static void testHashStringReturnsSha256Hex() {
        String hashValue = HashChainService.hashString('hello');

        System.assertEquals(64, hashValue.length());
        System.assertEquals(
            '2cf24dba5fb0a30e26e83b2ac5b9e29e1b161e5c1fa7425e73043362938b9824',
            hashValue
        );
    }

    @IsTest
    static void testComputeRecordHashNullHandling() {
        String hashValue = HashChainService.computeRecordHash(
            'a01234567890123456',
            1,
            'Decision',
            'Qualified Opportunity',
            null,
            null,
            null,
            null,
            'input',
            'output',
            'reasoning',
            ''
        );

        System.assertEquals(64, hashValue.length());
    }
}
